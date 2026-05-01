#!/usr/bin/env bash
# 04-export-dashboards.sh — export saved objects (dashboards, visualizations,
# index patterns, saved searches, etc.) from the LOCAL Dashboards instance
# at http://localhost:5601 into ./exports/dashboards.ndjson.
#
# Uses POST /api/saved_objects/_export with includeReferencesDeep=true so
# that dashboards bring along the visualizations and index patterns they
# depend on.
#
# Security is disabled on the local stack, so no auth headers are needed
# beyond `osd-xsrf: true`.

set -euo pipefail
cd "$(dirname "$0")"

DASH_URL="${DASH_URL:-http://localhost:5601}"
EXPORT_DIR="${EXPORT_DIR:-./exports}"
OUT_FILE="$EXPORT_DIR/dashboards.ndjson"

mkdir -p "$EXPORT_DIR"

# Object types worth exporting. config/telemetry/usage are intentionally
# omitted — they're per-installation and shouldn't be migrated.
TYPES='["dashboard","visualization","index-pattern","search","map","lens","canvas-workpad","canvas-element","query","tag","url"]'

echo "Source Dashboards: $DASH_URL"

# Make sure Dashboards is up.
if ! curl -fsS --max-time 10 "$DASH_URL/api/status" >/dev/null; then
  echo "ERROR: Dashboards not reachable at $DASH_URL." >&2
  echo "       Check 'docker compose ps' and 'docker compose logs dashboards'." >&2
  exit 1
fi

echo "Requesting saved-objects export..."
http_code=$(curl -sS -o "$OUT_FILE" -w '%{http_code}' \
  --max-time 60 \
  -X POST "$DASH_URL/api/saved_objects/_export" \
  -H 'Content-Type: application/json' \
  -H 'osd-xsrf: true' \
  -d "{\"type\": $TYPES, \"includeReferencesDeep\": true, \"excludeExportDetails\": false}")

if [[ "$http_code" != "200" ]]; then
  echo "ERROR: export returned HTTP $http_code" >&2
  echo "  body:" >&2
  head -c 1000 "$OUT_FILE" >&2
  echo >&2
  exit 1
fi

# Last line of a successful export is a JSON summary like:
#   {"exportedCount":14,"missingRefCount":0,"missingReferences":[]}
summary=$(tail -n 1 "$OUT_FILE")
count=$(echo "$summary" | jq -r '.exportedCount // "?"')
missing=$(echo "$summary" | jq -r '.missingRefCount // 0')

echo
echo "Exported $count saved objects to $OUT_FILE"
if [[ "$missing" != "0" ]]; then
  echo "WARN: $missing missing references — these dashboards/visualizations" >&2
  echo "      reference objects that don't exist locally and won't resolve." >&2
  echo "      Details:" >&2
  echo "$summary" | jq '.missingReferences' >&2
fi

# Quick breakdown by type for sanity.
echo
echo "Breakdown by type:"
# Skip the last line (summary), count by .type
head -n -1 "$OUT_FILE" | jq -r '.type' | sort | uniq -c | sort -rn | sed 's/^/  /'
