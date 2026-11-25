# Home Network & Cellular Internet Observability

## 1. Architecture & Platform Decision

Network and T-Mobile G4SE cellular observability is deployed on **K3s** (`monitoring` namespace) as the local Helm chart `k8s/charts/network-observability` managed through [k8s/charts/helmfile.yaml](file:///k8s/charts/helmfile.yaml).

### Components Reused vs. Newly Introduced

- **Reused:**
  - `kube-prometheus-stack` (`mon` release in `monitoring`): Prometheus `v3.9.1`, Alertmanager (Slack `#homelab-alerts`), Grafana sidecar (`grafana_dashboard: "1"` auto-provisioning), default Prometheus datasource (`uid: prometheus`), and Longhorn storage class `longhorn-master`.
- **Newly introduced:**
  - **Prometheus JSON Exporter** (`quay.io/prometheuscommunity/json-exporter:v0.8.0`): scrapes `http://192.168.12.1/TMI/v1/gateway/?get=signal` every 15 seconds on demand via `/probe?module=g4se_signal`.
  - **Prometheus Blackbox Exporter** (`quay.io/prometheus/blackbox-exporter:v0.29.1`): executes strict IPv4-only and IPv6-only ICMP, DNS, and HTTPS probes.
  - Declarative `ServiceMonitor`, `ScrapeConfig` (`monitoring.coreos.com/v1alpha1`), `PrometheusRule`, and Grafana `ConfigMap` manifests.

### Why K3s Instead of Docker Swarm

All monitoring infrastructure (Prometheus, Alertmanager, Grafana, Loki, Promtail, ServiceMonitors, and PrometheusRules) already lives in the `monitoring` namespace on K3s, and `monitoring.coreos.com/v1alpha1` (`ScrapeConfig`) + `PrometheusRule` reconcile declaratively via `helmfile` on push to `master`. Deploying exporters on Swarm would split alerting, retention, and deployment lifecycles across orchestrators for zero benefit.

### Security & Networking Exceptions (`hostNetwork: true` & `CAP_NET_RAW`)

- **`json-exporter`:** Runs as non-root (`65534`) on normal K3s pod networking (`10.42.0.0/24`). Runtime testing confirmed pod networking reaches `http://192.168.12.1/TMI/v1/gateway/?get=signal` over IPv4. Protected by a `ClusterIP` Service and a `NetworkPolicy` permitting ingress on TCP `7979` only from Prometheus (`app.kubernetes.io/name: prometheus`).
- **`blackbox-exporter`:** Live testing on `master` showed K3s pod networking has no IPv6 address or IPv6 route, and `sysctl net.ipv4.ping_group_range` is `1 0` (disabling unprivileged ICMP sockets). Therefore, `blackbox-exporter` uses:
  - `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet` and `nodeSelector: master` so IPv6 probes use `eno1` (`2607:fb90:6881:4d75::/64`).
  - `runAsUser: 0`, `privileged: false`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: { drop: ["ALL"], add: ["NET_RAW"] }`, and `seccompProfile: RuntimeDefault` (no blanket `privileged: true`).
  - `--web.listen-address=10.42.0.1:9115` (K3s `cni0` bridge IP only) with no Kubernetes `Service` or `NodePort`, preventing SSRF or arbitrary probing from LAN (`192.168.50.0/24`) or Tailscale peers.

### DNS Director & Verified DoT Constraint

Live verification on `master` confirmed that ASUS DNS Director + Stubby intercepts/refuses direct client TCP port `853` DoT handshakes to AdGuard (`94.140.14.15:853`, `94.140.15.16:853`, `[2a10:50c0::bad1:ff]:853` return `connect:errno=111`). Because router DNS enforcement must remain intact:

- `tcp_dot_ipv4` and `tcp_dot_ipv6` modules are defined in `blackbox.yml` for future external/VPS vantage points, not scheduled from `master`.
- End-to-end DNS responsiveness is measured against the local ASUS resolver (`192.168.50.1:53`, labeled `dns_policy: asus_dns_director_stubby_adguard_dot`) alongside ICMP checks to AdGuard's IPv4 and IPv6 upstream endpoints.
- Tailscale MagicDNS and `home.lab` resolution are untouched.

---

## 2. Metrics, Targets & Resource Estimates

### G4SE Cellular Metrics (`g4se-cellular`, 15s interval)

Only non-identifying radio and link-status fields are scraped (no IMEI, IMSI, ICCID, SIM, or phone numbers):

- `g4se_5g_sinr_db`, `g4se_5g_rsrp_dbm`, `g4se_5g_rsrq_db`, `g4se_5g_rssi_dbm`, `g4se_5g_signal_bars`
- `g4se_5g_cell_id`, `g4se_5g_gnb_id`
- `g4se_5g_band_info{band="..."}` (emits one series per element in `.signal["5g"].bands[*]`, handling multi-band carrier aggregation)
- `g4se_5g_antenna_info{antenna_used="..."}`
- `g4se_generic_ipv6_enabled`, `g4se_generic_roaming`, `g4se_generic_registration_info{registration="..."}`
- Missing keys (`allow_missing_key: true`) are omitted rather than zero-filled; `null` JSON values map to `NaN` in `json_exporter`; HTTP/JSON failures return HTTP `503` so `up{job="g4se-cellular"}` becomes `0`.

### Probe Classes & Intervals

| Class | Interval | Targets | Protocol / Policy |
| :--- | :--- | :--- | :--- |
| Core ICMP IPv4 | `5s` | `192.168.50.1` (`asus-router`), `192.168.12.1` (`g4se-gateway`), `8.8.8.8` (`google-v4`), `9.9.9.9` (`quad9-v4`), `1.1.1.1` (`cloudflare-v4`, `target_class="diagnostic_external"`) | `icmp_ipv4`, `ip_protocol_fallback: false` |
| Core ICMP IPv6 | `5s` | `2001:4860:4860::8888` (`google-v6`), `2606:4700:4700::1111` (`cloudflare-v6`) | `icmp_ipv6`, `ip_protocol_fallback: false` |
| Secondary ICMP | `15s` | `94.140.14.15`, `94.140.15.16` (IPv4), `2a10:50c0::bad1:ff`, `2a10:50c0::bad2:ff` (IPv6) | `icmp_ipv4` / `icmp_ipv6`, `ip_protocol_fallback: false` |
| Local DNS | `30s` | `192.168.50.1:53` (`asus-dns-local`) | `dns_local_ipv4` (`asus_dns_director_stubby_adguard_dot`) |
| Direct HTTPS | `30s` | `https://www.gstatic.com/generate_204`, `https://cp.cloudflare.com/generate_204` | `http_2xx_ipv4` and `http_2xx_ipv6` |

### Resource & Storage Estimates

- **Active series added:** ~250-350 time series across G4SE gauges, Blackbox probe outputs (`~12-18` series per target across 16 targets), and 5 recording rules.
- **Ingestion rate:** ~45-55 samples/second added to Prometheus (`5s` probes * ~18 series + `15s`/`30s` probes + G4SE).
- **Retention & disk:** Prometheus storage increases from `7d / 8GiB / 10Gi` to `30d / 20GiB / 25Gi` (`longhorn-master` had `54.9 GiB` available on `master`). At the observed baseline (~4.2 GiB for 7d -> ~0.6 GiB/day) plus ~50-80 MB/day for network observability, 30d steady state is ~19-21 GiB (fits comfortably inside `25Gi` PVC with `20GiB` WAL/TSDB cap).
- **CPU / RAM budgets:**
  - `json-exporter`: `10m / 16Mi` requested, `100m / 64Mi` limit (~5-15 MiB RSS expected).
  - `blackbox-exporter`: `15m / 24Mi` requested, `150m / 96Mi` limit (~15-30 MiB RSS expected).

---

## 3. Alerting Strategy & Threshold Tuning

Alerts are split by failure domain and wired through existing Alertmanager Slack notifications (`#homelab-alerts`) with inhibition rules in [k8s/charts/values-monitor.yaml](file:///k8s/charts/values-monitor.yaml):

- `HomeLocalRouterUnreachable` (`critical`, 2m): `192.168.50.1` <50% success. Inhibits gateway, API, DNS, and external outage alerts.
- `HomeGatewayUnreachable` (`critical`, 3m): `192.168.12.1` <50% success. Inhibits API and external alerts.
- `HomeG4SEAPIScrapeFailing` (`warning`, 5m): `up{job="g4se-cellular"} == 0` or `absent(g4se_5g_sinr_db)`.
- `HomeCellularPoorSINR` (`warning`, 15m): 15m avg SINR `< 0 dB` (sustained window absorbs transient cellular noise).
- `HomeInternetMultiTargetOutage` (`critical`, 3m): `>= 3` `core_external` targets (`google-v4`, `quad9-v4`, `google-v6`, `cloudflare-v6`) <50% success. Intentionally excludes `cloudflare-v4` (`1.1.1.1`, labeled `diagnostic_external`) so known `1.1.1.1` packet loss cannot page as a general internet outage.
- `HomeInternetIPv4OnlyDegradation` / `HomeInternetIPv6OnlyDegradation` (`warning`, 5m): `>= 2` core targets >20% probe failure in one family while `>= 2` core targets in the other family stay <5% failure.
- `HomeExternalLatencyBaselineDegraded` (`warning`, 15m): avg 5m median RTT across `core_external` `> 120 ms`. Tune upward if normal evening tower congestion averages >120 ms after 7 days of baseline data.
- `HomeLocalDNSFailing` (`warning`, 5m): `asus-dns-local` <50% success.

Rolling failure percentage metrics (`network:probe_failure_ratio:5m`) represent failed-probe ratios across 5s samples, not continuous L2/L3 packet-loss counters.

---

## 4. Deployment & Rollback Runbooks

### Pre-Deployment: Expand Prometheus PVC (`10Gi` -> `25Gi`)

Kubernetes does not allow modifying `volumeClaimTemplates` on an existing `StatefulSet` in place. Expand the live Longhorn PVC before running Helmfile apply so Prometheus can retain 30 days (`20GiB`):

```bash
kubectl get pvc -n monitoring prometheus-mon-kube-prometheus-stack-prometheus-db-prometheus-mon-kube-prometheus-stack-prometheus-0
kubectl patch pvc -n monitoring prometheus-mon-kube-prometheus-stack-prometheus-db-prometheus-mon-kube-prometheus-stack-prometheus-0 \
  --type merge -p '{"spec":{"resources":{"requests":{"storage":"25Gi"}}}}'
kubectl get pvc -n monitoring prometheus-mon-kube-prometheus-stack-prometheus-db-prometheus-mon-kube-prometheus-stack-prometheus-0 -w
```

If `mon` StatefulSet upgrade later rejects an unchanged-name template diff in `helmfile`, delete the StatefulSet with `--cascade=orphan` before running `helmfile apply` (pods and PVC remain intact; Prometheus Operator recreates the StatefulSet cleanly).

### Deployment Commands

```bash
task net:test
task charts:lint:all
task charts:diff
task charts:apply
```

### Post-Deployment Live Verification

```bash
kubectl get pods,svc,networkpolicy,servicemonitor,scrapeconfig,prometheusrule -n monitoring | grep network-observability
kubectl get cm -n monitoring network-observability-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}{"\n"}'
kubectl exec -n monitoring deploy/network-observability-blackbox-exporter -- sh -c 'wget -qO- "http://10.42.0.1:9115/probe?target=2001:4860:4860::8888&module=icmp_ipv6" | grep -E "probe_success|probe_icmp_duration_seconds"'
kubectl exec -n monitoring prometheus-mon-kube-prometheus-stack-prometheus-0 -c prometheus -- sh -c 'wget -qO- "http://localhost:9090/api/v1/query?query=g4se_5g_sinr_db" && wget -qO- "http://localhost:9090/api/v1/query?query=probe_success"'
```

Confirm on `master` that Blackbox Exporter is NOT reachable from LAN or Tailscale:

```bash
ss -tlnp | grep 9115   # expected: 10.42.0.1:9115 only
```

### Rollback Commands

```bash
helm -n monitoring uninstall network-observability
# If reverting values-monitor.yaml retention changes via git revert:
git revert <commit-sha>
task charts:apply
```

Note: Existing 30d TSDB samples in the expanded `25Gi` PVC stay safe if retention is lowered back to `7d` / `8GiB` (Prometheus will prune older blocks on compaction without shrinking the PVC).

---

## 5. Temporary Collector (`g4se-collector.service`) & Historical Data

The existing user systemd unit `g4se-collector.service` (`~/.local/bin/g4se-collector`) writes 15-second JSONL telemetry to `~/network-benchmarks/telemetry/g4se-YYYY-MM-DD.jsonl`.

- **Recommendation on backfill:** Preserve the raw `.jsonl` files rather than running a Prometheus `tsdb create-blocks-from openmetrics` backfill. Backfilling requires regenerating blocks offline against overlapping time windows of a live TSDB PVC for only a few days of pre-deployment samples; keeping the `.jsonl` archive is zero-risk and immediately readable with `jq` / Python for any pre-cutover baseline comparison.
- **Retirement steps (run only after >=24h of verified Prometheus `g4se_5g_*` scraping):**

```bash
systemctl --user disable --now g4se-collector.service
mkdir -p ~/network-benchmarks/telemetry/archive
# Keep historical JSONL files archived read-only:
chmod a-w ~/network-benchmarks/telemetry/g4se-*.jsonl
mv ~/network-benchmarks/telemetry/g4se-*.jsonl ~/network-benchmarks/telemetry/archive/
```

---

## 6. Operational Troubleshooting

- **`blackbox-exporter` fails to bind `10.42.0.1:9115` after reboot:** `cni0` bridge IP `10.42.0.1` is created by K3s/Flannel; `Recreate` strategy + `livenessProbe` restarts the pod once `cni0` is up. Check `ip addr show cni0` and pod events (`kubectl describe pod -n monitoring -l app.kubernetes.io/name=network-observability-blackbox-exporter`).
- **IPv6 probes fail with `network is unreachable`:** Confirm `eno1` still has a global IPv6 prefix and RA default route (`ip -6 addr show eno1 && ip -6 route`).
- **`HomeG4SEAPIScrapeFailing` fires:** Test direct gateway reachability from `master` and Prometheus pod (`curl -fsS --max-time 5 'http://192.168.12.1/TMI/v1/gateway/?get=signal'`). If the gateway firmware changed JSON keys, inspect `kubectl logs -n monitoring deploy/network-observability-json-exporter`.

---

## 7. Gateway Placement & CAKE Experiment Workflow

1. Record a **Grafana annotation** at every experiment boundary using [scripts/network-annotate.sh](file:///Users/gordonpn/workspace/homelab/scripts/network-annotate.sh) (uses `GRAFANA_TOKEN` or `GRAFANA_USER`/`GRAFANA_PASSWORD`, zero secrets in Git):

```bash
export GRAFANA_USER=admin
export GRAFANA_PASSWORD="<from secret or Keychain>"
task net:annotate -- '"Moved G4SE to south window (+45 deg)"' 'gateway-relocation'
task net:annotate -- '"Enabled cake-autorate v3.2.1 (eth4 / ifb4eth4)"' 'cake-autorate'
task net:annotate -- '"Flent RRUL 60s baseline run"' 'rrul-benchmark'
```

2. Use the **"Correlation & Experiments"** dashboard section with `graphTooltip` shared crosshair and `-24h` / `-7d` overlays to compare SINR, RSRP, CID transitions, and p95/p99 RTT before and after each annotation.
3. Let each placement sit at least 24 hours across evening peak hours before changing a second variable.

---

## 8. Future Extensibility Backlog

1. **ASUS Router & CAKE Queue Exporter (`eth4` / `ifb4eth4`):** Collect `tc -s qdisc show dev eth4` / `ifb4eth4` drops, backlog, target delay, and `cake-autorate` shaping rates via a lightweight read-only metrics endpoint (never exposing router SSH keys to Prometheus/Grafana and never allowing monitoring to alter shaping rates).
2. **External RackNerd VPS Probing:** Deploy a matching `blackbox-exporter` instance on `racknerd-edc1bc8` (including `tcp_dot_ipv4`/`tcp_dot_ipv6` and home ingress HTTP probes) labeled `location="racknerd-vps"`.
3. **Flent RRUL & Low-Frequency Speedtest Metadata:** Run bounded scheduled RRUL benchmarks manually/low-frequency, record timestamps with `task net:annotate`, and optionally expose summary metrics via `pushgateway`.
4. **Tailscale Path Monitoring:** Track direct vs DERP-relayed peer status between `master` and `racknerd-edc1bc8`.
