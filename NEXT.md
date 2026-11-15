# Execution Queue (Verified Snapshot: `2026-11-15`)

Verified against `origin/master` at commit `6b6d5004d69c126ad1c7b11cf9f658b80cdb6cdc` (repository default branch is `master`).
GitHub Issues are the source of truth for task definitions and status; this file is a derived execution snapshot.

## NOW (Select 1 READY Issue)

- **#70** - `[Security][P1] Remove public host port exposure on FlareSolverr SSRF proxy and bind media stack admin ports to localhost/Tailscale` (`priority:p1`, `effort:xs`, `security`, `architecture`)
  - Why now: Eliminates an unauthenticated `0.0.0.0:8191` SSRF proxy on `master` that bypasses UFW rules and can pivot to internal K3s NodePorts (`30090`, `30093`, `30900`, `31100`) and media APIs. Smallest (`XS`) high-severity fix with zero blockers.
  - Pre-check: Confirm Prowlarr's runtime indexer proxy config targets `http://flaresolverr:8191` before removing host port `8191:8191`.

## NEXT (Ordered Ready Queue)

1. **#67** - `[Security][P1] Demote edge VPS (racknerd-edc1bc8) from Docker Swarm Manager and isolate per-node monitoring secrets` (`priority:p1`, `effort:s`, `security`, `architecture`)
   - Closes the DMZ privilege boundary where `racknerd-edc1bc8` sits as a Swarm Manager (`Reachable`), restores single-manager Swarm resilience on `master`, and stops injecting `MASTER_TOKEN` onto the VPS. Coordinate `#47` token pruning in the same files if helpful.
2. **#44** - `[Security] Replace plaintext MinIO root credentials with SealedSecret in k3s-maintenance` (`priority:p1`, `effort:s`, `security`)
   - Replaces hardcoded `minioadmin`/`minioadminsecret` protecting Longhorn volume backups and `homelab` OpenTofu state on NodePorts `30900`/`30901`.
3. **#66** - `[Security][P1] Isolate ARC runner ServiceAccounts and revoke cluster-admin from scraper runner scale set` (`priority:p1`, `effort:s`, `security`, `architecture`, `ci-cd`)
   - Moves `arc-runner-set-scraper` (`home-lab-runners-scraper`) off `cluster-admin` onto a dedicated `scraper-runner` ServiceAccount scoped to `default` (`batch/v1` `cronjobs`) and `monitoring` (`configmaps/lectures-notifier-dashboard`).
4. **#46** - `[CI/CD] Add pull request validation and concurrency controls to GitOps Helmfile workflow` (`priority:p1`, `effort:s`, `ci-cd`)
   - Adds PR validation (`task charts:lint:all`, `task charts:template`), `concurrency:`, `permissions: contents: read`, `timeout-minutes`, and extracts inline tool installs from `.github/workflows/gitops.yml`.
5. **#68** - `[Security][P1] Enforce SHA256 checksum verification for CI/CD binaries and pin GitHub Actions to commit SHAs` (`priority:p1`, `effort:s`, `security`, `ci-cd`, `dependencies`)
   - Pairs with `#46` to pin SHA256 digests in all `scripts/ci/setup-*.sh` scripts and pin `actions/checkout` / `reviewdog/action-actionlint` to 40-char commit SHAs with `persist-credentials: false`.

## LATER

### High Priority / Unblocked Follow-On
- **#69** (`P1 / M`): Restrict `0777` MinIO hostPath permissions, secure unauthenticated NodePorts (`30090`, `30093`, `31100`) and Grafana admin secret while preserving Tailscale CLI/Promtail access, and audit/harden `redis`.
- **#33** (`P1 / M`): Automate encrypted offsite replication of MinIO `terraform-state` (Cloudflare R2 / B2).
- **#22** (`P1 / S`): Export Northflank Uptime Kuma `/metrics` into Prometheus declaratively.
- **#11** (`P1 / XL` Initiative) -> **#12** (`P1 / XL` Epic): Cloud failure domains and OCI A1 offsite DR. Ready entry point: **#14** (`P1 / M`, OCI A1 foundation). Blocked downstream: **#15** (on `#14`), **#35** (on `#14`, `#33`), **#16** (on `#14`, `#15`, `#35`), **#17** (on `#14`–`#16`, `#35`).

### Normal Priority (`P2`)
- **#45** (`P2 / S`, Bug): Exclude `node-role.kubernetes.io/remote` from `network-crossnode-check` to stop false-positive `KubeJobFailed` alerts.
- **#50** (`P2 / XS`): Align `coredns-config-enforcer` target replicas from `5` to `2`.
- **#54** (`P2 / XS`): Pin mutable `ntfy` tag in `k8s/charts/workloads/values.yaml`.
- **#47** (`P2 / S`): Prune decommissioned Raspberry Pi tokens (`pi-bos-0`, `pi-mtl-0`, `pi-mtl-1`) and `install-bos-0.yaml`.
- **#49** (`P2 / S`): Replace/retire uncoordinated `k3s-monthly-restart` CronJob.
- **#71** (`P2 / S`): Harden Ntfy default access (`deny-all` after client audit), pass `TUNNEL_TOKEN` via env in `cloudflared`, harden Caddy headers/`whoami`, add `_dmarc`.
- **#72** (`P2 / XS`): Restrict `pr-agent.yml` `issue_comment` on forks and exclude secret patterns from external LLM review.
- **#73** (`P2 / S`): Pin `k3s-maintenance` images and harden `workloads` `securityContext`, `automountServiceAccountToken: false`, and `resources` (coordinates with `#49`, `#54`).
- **#52** (`P2 / S`): Migrate deprecated `cloudflare_tunnel` / `cloudflare_tunnel_config` resources in `terraform/tunnels.tf`.

### Low Priority (`P3`) & On Hold
- **#76** (`P3 / XS`): Remove unused `healthchecksio_api_key` from local `terraform.tfvars` and `TF_VAR_HEALTHCHECKSIO_API_KEY` secret.
- **#51** (`P3 / XS`): Consolidate ARC `SealedSecret` manifests (including `github-actions-runner-token-scraper`) and remove dead `k8s/charts/monitoring/`.
- **#53** (`P3 / XS`): Expand `task ci:lint` across all workflows and active scripts.
- **#77** (`P3 / XS`): Refresh `README.md` for 2-node topology, `Taskfile.yaml`/GitOps workflows, and remove retired Healthchecks badge (and retire obsolete `scripts/backup.sh` references now that `#48` is closed).
- **#74** (`P3 / S`): Add Gitleaks + Zizmor/Trivy security checks to PR CI.
- **#55** (`P3 / S`): Audit/archive 18 inactive `docker-swarm/` stacks and verify/remove orphaned `swarmpit`/`portainer`/`jenkins` DNS CNAMEs.
- **#65** (`P3 / M`): Migrate app-targeted Cloudflare DNS (`apex`, `www`, `gym`, `notes`) to their app repos.
- **#13** (`P3 / L`, `status: on hold`) -> **#18** (`S`), **#19** (`M`): Optional GCP `e2-micro` utility/ingress redundancy; deferred until OCI `#12` is addressed.
