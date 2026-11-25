#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/k8s/charts/network-observability"
FIXTURE_DIR="${ROOT_DIR}/tests/fixtures/g4se"

JSON_EXPORTER_BIN="${JSON_EXPORTER_BIN:-$(command -v json_exporter || true)}"
BLACKBOX_EXPORTER_BIN="${BLACKBOX_EXPORTER_BIN:-$(command -v blackbox_exporter || true)}"
PROMTOOL_BIN="${PROMTOOL_BIN:-$(command -v promtool || true)}"

for dep in helm jq python3 curl; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Missing required tool: $dep" >&2
    exit 1
  fi
done

if ! command -v ruby >/dev/null 2>&1 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "Missing YAML parser: install ruby (with stdlib yaml) or Python PyYAML (e.g. pip install pyyaml)" >&2
  exit 1
fi

echo "==> 1. Helm lint & template rendering"
helm lint "$CHART_DIR" >/dev/null
RENDERED="$(mktemp)"
TMP_DIR="$(mktemp -d)"
FIXTURE_PID=""
EXPORTER_PID=""
cleanup() {
  if [ -n "${EXPORTER_PID:-}" ]; then kill "$EXPORTER_PID" >/dev/null 2>&1 || true; fi
  if [ -n "${FIXTURE_PID:-}" ]; then kill "$FIXTURE_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$RENDERED" "$TMP_DIR"
}
trap cleanup EXIT

helm template network-observability "$CHART_DIR" --namespace monitoring >"$RENDERED"
test -s "$RENDERED"

yaml_stream_to_json() {
  local yaml_file="$1"
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'YAML.load_stream(File.read(ARGV[0])) { |d| puts JSON.generate(d) if d }' "$yaml_file"
  else
    python3 -c 'import json, sys, yaml; [print(json.dumps(d)) for d in yaml.safe_load_all(open(sys.argv[1])) if d]' "$yaml_file"
  fi
}

echo "==> 2. Verify Kubernetes security and networking invariants"
JSON_RENDERED="${TMP_DIR}/rendered.jsonl"
yaml_stream_to_json "$RENDERED" >"$JSON_RENDERED"
python3 - "$JSON_RENDERED" <<'PY'
import json
import sys

docs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
kinds = {(d["kind"], d["metadata"]["name"]) for d in docs}
assert ("Deployment", "network-observability-json-exporter") in kinds
assert ("Deployment", "network-observability-blackbox-exporter") in kinds
assert ("NetworkPolicy", "network-observability-json-exporter") in kinds
assert ("PrometheusRule", "network-observability-rules") in kinds
assert ("ConfigMap", "network-observability-dashboard") in kinds
assert ("ServiceMonitor", "network-observability-json-exporter") in kinds

scrape_names = {d["metadata"]["name"] for d in docs if d["kind"] == "ScrapeConfig"}
expected_scrapes = {
    "network-observability-blackbox-exporter",
    "network-observability-g4se-cellular",
    "network-observability-icmp-ipv4-core",
    "network-observability-icmp-ipv6-core",
    "network-observability-icmp-ipv4-secondary",
    "network-observability-icmp-ipv6-secondary",
    "network-observability-dns-local-ipv4",
    "network-observability-https-ipv4",
    "network-observability-https-ipv6",
}
assert scrape_names == expected_scrapes, f"Unexpected ScrapeConfigs: {scrape_names}"

for d in docs:
    if d["kind"] == "Service":
        assert d["spec"].get("type") != "NodePort", f"Unexpected NodePort on {d['metadata']['name']}"
    if d["kind"] == "Deployment":
        spec = d["spec"]["template"]["spec"]
        assert spec.get("automountServiceAccountToken") is False
        assert spec.get("nodeSelector", {}).get("kubernetes.io/hostname") == "master"
        c = spec["containers"][0]
        sc = c["securityContext"]
        assert sc.get("privileged") is not True
        assert sc.get("allowPrivilegeEscalation") is False
        assert sc.get("readOnlyRootFilesystem") is True
        assert "ALL" in sc.get("capabilities", {}).get("drop", [])
        assert c["resources"]["requests"]["cpu"]
        assert c["resources"]["limits"]["memory"]
        if d["metadata"]["name"] == "network-observability-json-exporter":
            assert spec.get("hostNetwork") is not True
            assert spec["securityContext"]["runAsNonRoot"] is True
        if d["metadata"]["name"] == "network-observability-blackbox-exporter":
            assert spec.get("hostNetwork") is True
            assert spec.get("dnsPolicy") == "ClusterFirstWithHostNet"
            assert "NET_RAW" in sc.get("capabilities", {}).get("add", [])
            assert any(a == "--web.listen-address=10.42.0.1:9115" for a in c["args"])

print("PASS: Helm manifest security & ScrapeConfig invariants")
PY

for custom_location in "test-site" "lab: west"; do
  RENDERED_CUSTOM="${TMP_DIR}/rendered-custom.yaml"
  helm template network-observability "$CHART_DIR" --namespace monitoring --set "location=${custom_location}" >"$RENDERED_CUSTOM"
  JSON_CUSTOM="${TMP_DIR}/rendered-custom.jsonl"
  yaml_stream_to_json "$RENDERED_CUSTOM" >"$JSON_CUSTOM"
  python3 - "$JSON_CUSTOM" "$custom_location" <<'PY'
import json
import sys

docs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
expected_location = sys.argv[2]
rules = [d for d in docs if d["kind"] == "PrometheusRule"]
assert len(rules) == 1
exprs = [r["expr"] for g in rules[0]["spec"]["groups"] for r in g["rules"]]
annots = [str(v) for g in rules[0]["spec"]["groups"] for r in g["rules"] for v in r.get("annotations", {}).values()]
expr_text = "\n".join(exprs)
annot_text = "\n".join(annots)
assert f'location="{expected_location}"' in expr_text, f"PrometheusRule must honor custom location {expected_location!r}"
assert 'location="home-nuc"' not in expr_text, "PrometheusRule must not retain hard-coded home-nuc location"
assert "{{ $labels.job }}" in annot_text, "Prometheus annotation templates must remain intact"
assert "{{ $value" in annot_text, "Prometheus value annotation templates must remain intact"
print(f"PASS: PrometheusRule custom location ({expected_location}) preserves PromQL templates")
PY
done

echo "==> 3. Validate Blackbox configuration semantics"
BLACKBOX_JSON="${TMP_DIR}/blackbox.json"
yaml_stream_to_json "${CHART_DIR}/files/blackbox.yml" >"$BLACKBOX_JSON"
python3 - "$BLACKBOX_JSON" <<'PY'
import json, sys
cfg = json.loads(open(sys.argv[1]).readline())
mods = cfg["modules"]
for name in ["icmp_ipv4", "icmp_ipv6", "http_2xx_ipv4", "http_2xx_ipv6", "dns_local_ipv4", "tcp_dot_ipv4", "tcp_dot_ipv6"]:
    assert name in mods, f"Missing module {name}"
    prober = mods[name]["prober"]
    assert mods[name][prober]["ip_protocol_fallback"] is False, f"Fallback must be false in {name}"
assert mods["icmp_ipv4"]["icmp"]["preferred_ip_protocol"] == "ip4"
assert mods["icmp_ipv6"]["icmp"]["preferred_ip_protocol"] == "ip6"
answer_regexps = mods["dns_local_ipv4"]["dns"].get("validate_answer_rrs", {}).get("fail_if_none_matches_regexp", [])
assert len(answer_regexps) >= 1, "dns_local_ipv4 must validate presence of an IN A answer record"
print("PASS: Blackbox IPv4/IPv6 no-fallback & DNS answer validation")
PY

echo "==> 4. Validate Grafana dashboard JSON structure"
jq -e '
  .title == "Home Internet & Cellular Network Observability" and
  .uid == "home-network-cellular-observability" and
  (.templating.list | map(.name) | index("location") != null and index("protocol") != null and index("target") != null) and
  (.annotations.list | any(.tags? // [] | index("network-experiment") != null)) and
  (.panels | map(select(.type == "row") | .title) == [
    "Overview",
    "Cellular Radio Quality",
    "Network Latency",
    "Availability",
    "Correlation & Experiments"
  ]) and
  ([.panels[] | select(.type != "row") | .targets[]? | .expr] | all(type == "string" and length > 0)) and
  (.panels[] | select(.id == 6) | .options.textMode == "value_and_name") and
  (.panels[] | select(.id == 11) | .targets[0].expr | contains("> 0")) and
  (.panels[] | select(.id == 24) | .targets[0].expr | (contains("phase=\"request\"") and contains("ignoring(phase)") and contains("probe_success")))
' "${CHART_DIR}/files/grafana-dashboard.json" >/dev/null
echo "PASS: Grafana dashboard JSON validation"

if [ -n "$BLACKBOX_EXPORTER_BIN" ]; then
  echo "==> 5. Running blackbox_exporter --config.check"
  "$BLACKBOX_EXPORTER_BIN" --config.file="${CHART_DIR}/files/blackbox.yml" --config.check
else
  echo "SKIP: blackbox_exporter binary not found (set BLACKBOX_EXPORTER_BIN to enable)"
fi

if [ -n "$PROMTOOL_BIN" ]; then
  echo "==> 6. Running promtool check rules"
  "$PROMTOOL_BIN" check rules "${CHART_DIR}/files/prometheus-rules.yaml"
else
  echo "SKIP: promtool binary not found (set PROMTOOL_BIN to enable)"
fi

if [ -n "$JSON_EXPORTER_BIN" ]; then
  echo "==> 7. Running json_exporter --config.check and fixture extraction tests"
  "$JSON_EXPORTER_BIN" --config.file="${CHART_DIR}/files/json-exporter.yml" --config.check

  cp "${FIXTURE_DIR}/"*.json "$TMP_DIR/"
  FIXTURE_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  EXPORTER_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

  python3 - "$TMP_DIR" "$FIXTURE_PORT" <<'PY' >/dev/null 2>&1 &
import http.server, os, sys
root, port = sys.argv[1], int(sys.argv[2])
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)
    def do_GET(self):
        if self.path == "/fail500":
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"gateway error")
            return
        return super().do_GET()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
  FIXTURE_PID=$!

  "$JSON_EXPORTER_BIN" \
    --config.file="${CHART_DIR}/files/json-exporter.yml" \
    --web.listen-address="127.0.0.1:${EXPORTER_PORT}" >/dev/null 2>&1 &
  EXPORTER_PID=$!

  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${FIXTURE_PORT}/normal-single-band.json" >/dev/null 2>&1 && \
       curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done

  NORMAL_OUT="$(curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/probe?module=g4se_signal&target=http://127.0.0.1:${FIXTURE_PORT}/normal-single-band.json")"
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_sinr_db 6$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_rsrp_dbm -89$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_rsrq_db -11$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_rssi_dbm -77$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_signal_bars 4$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_cell_id 45$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_gnb_id 4.837985e+06$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_band_info{band="n41"} 1$'
  echo "$NORMAL_OUT" | grep -q '^g4se_5g_antenna_info{antenna_used="Internal_directional"} 1$'
  echo "$NORMAL_OUT" | grep -q '^g4se_generic_ipv6_enabled 1$'

  MULTI_OUT="$(curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/probe?module=g4se_signal&target=http://127.0.0.1:${FIXTURE_PORT}/multi-band.json")"
  echo "$MULTI_OUT" | grep -q '^g4se_5g_band_info{band="n41"} 1$'
  echo "$MULTI_OUT" | grep -q '^g4se_5g_band_info{band="n71"} 1$'

  MISSING_OUT="$(curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/probe?module=g4se_signal&target=http://127.0.0.1:${FIXTURE_PORT}/missing-and-null.json")"
  echo "$MISSING_OUT" | grep -q '^g4se_5g_rsrp_dbm -104$'
  if echo "$MISSING_OUT" | grep -q '^g4se_5g_rsrq_db '; then
    echo "FAIL: missing rsrq should be omitted, not emitted" >&2
    exit 1
  fi
  if echo "$MISSING_OUT" | grep -qE '^g4se_5g_sinr_db 0($| )'; then
    echo "FAIL: null sinr must not be converted to 0" >&2
    exit 1
  fi
  if echo "$MISSING_OUT" | grep -q '^g4se_5g_band_info'; then
    echo "FAIL: empty bands array must emit zero band metrics" >&2
    exit 1
  fi

  MALFORMED_BODY="$(mktemp)"
  MALFORMED_CODE="$(curl -s -o "$MALFORMED_BODY" -w '%{http_code}' "http://127.0.0.1:${EXPORTER_PORT}/probe?module=g4se_signal&target=http://127.0.0.1:${FIXTURE_PORT}/malformed.json")"
  test "$MALFORMED_CODE" = "200"
  if grep -q '^g4se_5g_' "$MALFORMED_BODY"; then
    echo "FAIL: malformed JSON must not emit cellular metrics" >&2
    exit 1
  fi
  rm -f "$MALFORMED_BODY"
  ERR500_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${EXPORTER_PORT}/probe?module=g4se_signal&target=http://127.0.0.1:${FIXTURE_PORT}/fail500")"
  test "$ERR500_CODE" = "503"
  curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" >/dev/null
  echo "PASS: json_exporter fixture extraction (normal, multi-band, missing/null, malformed=$MALFORMED_CODE, upstream-500=$ERR500_CODE)"
else
  echo "SKIP: json_exporter binary not found (set JSON_EXPORTER_BIN to enable)"
fi

echo "PASS: all network-observability checks completed"
