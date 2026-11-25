#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/network-annotate.sh "<text>" [tag1,tag2,...]

Posts a Grafana annotation tagged with "network-experiment" (plus optional comma-separated tags).

Environment variables:
  GRAFANA_URL       Base Grafana URL (default: http://master.tailb65f8c.ts.net:30000)
  GRAFANA_TOKEN     Grafana service account token (preferred)
  GRAFANA_USER      Basic auth username when GRAFANA_TOKEN is unset
  GRAFANA_PASSWORD  Basic auth password when GRAFANA_TOKEN is unset
  DASHBOARD_UID     Optional dashboard UID scope (default: home-network-cellular-observability)
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

TEXT="$1"
EXTRA_TAGS="${2:-}"
GRAFANA_URL="${GRAFANA_URL:-http://master.tailb65f8c.ts.net:30000}"
DASHBOARD_UID="${DASHBOARD_UID:-home-network-cellular-observability}"

for dep in curl jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Missing required dependency: $dep" >&2
    exit 1
  fi
done

TAGS_JSON=$(jq -nc --arg extra "$EXTRA_TAGS" '
  (["network-experiment"] + ($extra | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))))
  | unique
')

TIME_MS=$(( $(date +%s) * 1000 ))

PAYLOAD=$(jq -nc \
  --arg dashboardUID "$DASHBOARD_UID" \
  --arg text "$TEXT" \
  --argjson time "$TIME_MS" \
  --argjson tags "$TAGS_JSON" \
  '{
    dashboardUID: $dashboardUID,
    time: $time,
    tags: $tags,
    text: $text
  }')

AUTH_ARGS=()
if [ -n "${GRAFANA_TOKEN:-}" ]; then
  AUTH_ARGS=(-H "Authorization: Bearer ${GRAFANA_TOKEN}")
elif [ -n "${GRAFANA_USER:-}" ] && [ -n "${GRAFANA_PASSWORD:-}" ]; then
  AUTH_ARGS=(-u "${GRAFANA_USER}:${GRAFANA_PASSWORD}")
else
  echo "Set GRAFANA_TOKEN or both GRAFANA_USER and GRAFANA_PASSWORD" >&2
  exit 1
fi

curl -fsS -X POST \
  "${AUTH_ARGS[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "${GRAFANA_URL%/}/api/annotations"
echo ""
