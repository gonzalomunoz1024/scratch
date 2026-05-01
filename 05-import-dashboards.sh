#!/usr/bin/env bash
# 05-import-dashboards.sh — import saved objects from ./exports/dashboards.ndjson
# into the TARGET Dashboards instance.
#
# Uses POST /api/saved_objects/_import?overwrite=true so that re-running
# the script is idempotent — if a dashboard with the same ID already
# exists, it gets replaced.
#
# Auth: target Dashboards is security-enabled. Most deployments accept
# the same admin credentials as the API. We send Basic auth + osd-xsrf.
#
# Notes on assumptions:
#   - The user data indices (hello-world, lightspeed-events, vmforge-events)
#     have already been imported into the target API. Index patterns
#     reference indices by NAME, so this matches by default.
#   - Index-pattern UUIDs are preserved on import, so dashboard -> viz ->
#     index-pattern reference chains stay intact.

set -euo pipefail
cd "$(dirname "$0")"

DASH_URL="${DASH_URL:-https://opensearch-dashboards-opensearch.apps.cml27.ocp.lab.wellsfargo.net}"
DASH_USER="${DASH_USER:-admin}"
DASH_PASS="${DASH_PASS:-${TARGET_PASS:-RuntimeCrew123}}"
EXPORT_DIR="${EXPORT_DIR:-./exports}"
IN_FILE="$EXPORT_DIR/dashboards.ndjson"

CURL_TIMEOUT="${CURL_TIMEOUT:-60}"
CURL_BASE=(-sS -k --max-time "$CURL_TIMEOUT" --retry 3 --retry-delay 2 --retry-connrefused \
           -u "${DASH_USER}:${DASH_PASS}" -H 'osd-xsrf: true')

die() { echo "ERROR: $*" >&2; exit 1; }

command -v jq   >/dev/null || die "jq is required"
command -v curl >/dev/null || die "curl is required"
[[ -f "$IN_FILE" ]] || die "$IN_FILE not found — run 04-export-dashboards.sh first"

echo "Target Dashboards: $DASH_URL"
echo "Input file: $IN_FILE ($(wc -l < "$IN_FILE" | tr -d ' ') lines)"

# ---- preflight: target reachable + auth works -------------------------------
echo "Probing target Dashboards status..."
status_resp=$(curl "${CURL_BASE[@]}" "$DASH_URL/api/status" 2>&1) \
  || die "could not reach target Dashboards: $status_resp"

# /api/status returns JSON. If we got HTML, that's a routing/auth problem.
if ! echo "$status_resp" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: /api/status didn't return JSON. First 500 chars:" >&2
  echo "$status_resp" | head -c 500 >&2
  echo >&2
  die "target Dashboards may be unreachable or auth is wrong"
fi

overall=$(echo "$status_resp" | jq -r '.status.overall.state // .status.overall.level // "unknown"')
echo "  status: $overall"

# ---- import -----------------------------------------------------------------
echo "POSTing saved objects (overwrite=true)..."

tmp_resp=$(mktemp)
trap 'rm -f "$tmp_resp"' EXIT

http_code=$(curl "${CURL_BASE[@]}" -o "$tmp_resp" -w '%{http_code}' \
  -X POST "$DASH_URL/api/saved_objects/_import?overwrite=true" \
  -H 'Content-Type: multipart/form-data' \
  --form "file=@${IN_FILE};type=application/ndjson")

if [[ "$http_code" != "200" ]]; then
  echo "ERROR: import returned HTTP $http_code" >&2
  echo "  response body (first 1000 chars):" >&2
  head -c 1000 "$tmp_resp" >&2
  echo >&2
  exit 1
fi

# Validate JSON.
if ! jq -e . "$tmp_resp" >/dev/null 2>&1; then
  echo "ERROR: response wasn't JSON. First 500 chars:" >&2
  head -c 500 "$tmp_resp" >&2
  echo >&2
  exit 1
fi

success=$(jq -r '.success // false' "$tmp_resp")
success_count=$(jq -r '.successCount // 0' "$tmp_resp")
errors=$(jq -c '.errors // []' "$tmp_resp")
n_errors=$(jq -r '.errors | length // 0' "$tmp_resp")

echo
echo "Import response:"
echo "  success: $success"
echo "  successCount: $success_count"
echo "  errors: $n_errors"

if [[ "$n_errors" != "0" ]]; then
  echo
  echo "Per-object errors:" >&2
  jq -r '.errors[] | "  - [\(.type)] id=\(.id) title=\(.title // "?") -> \(.error.type): \(.error.message // "")"' "$tmp_resp" >&2
fi

if [[ "$success" != "true" ]]; then
  exit 1
fi

echo
echo "Done. Saved objects imported into target Dashboards."
echo "Open $DASH_URL and verify dashboards/visualizations render."
