#!/usr/bin/env bash
# 02-export.sh — export user indices from the local source cluster
# into ./exports/ as JSON (settings, mapping) + NDJSON (docs ready for _bulk).
#
# Skips system indices: .opendistro_*, .opensearch-*, .kibana*, .ql-*,
# .plugins-*, security-auditlog*.
#
# Output per index <name>:
#   exports/<name>.settings.json   # GET /<name>/_settings
#   exports/<name>.mapping.json    # GET /<name>/_mapping
#   exports/<name>.docs.ndjson     # alternating action/source lines for _bulk

set -euo pipefail
cd "$(dirname "$0")"

SOURCE_URL="${SOURCE_URL:-http://localhost:9200}"
EXPORT_DIR="${EXPORT_DIR:-./exports}"
SCROLL_SIZE="${SCROLL_SIZE:-1000}"
SCROLL_TTL="${SCROLL_TTL:-2m}"

command -v jq   >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

mkdir -p "$EXPORT_DIR"

skip_index() {
  case "$1" in
    .opendistro_*|.opensearch-*|.kibana*|.ql-*|.plugins-*|security-auditlog*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Source: $SOURCE_URL"
echo "Listing indices..."
mapfile -t indices < <(
  curl -fsS "$SOURCE_URL/_cat/indices?h=index&expand_wildcards=all" \
    | awk 'NF' | sort
)
echo "  found ${#indices[@]} indices total"

exported=0
skipped=0

for idx in "${indices[@]}"; do
  if skip_index "$idx"; then
    echo "SKIP  $idx"
    skipped=$((skipped+1))
    continue
  fi

  echo
  echo "==> $idx"

  # settings + mapping
  curl -fsS "$SOURCE_URL/$idx/_settings" > "$EXPORT_DIR/$idx.settings.json"
  curl -fsS "$SOURCE_URL/$idx/_mapping"  > "$EXPORT_DIR/$idx.mapping.json"

  # scroll through all docs and emit NDJSON suitable for _bulk on the target
  out="$EXPORT_DIR/$idx.docs.ndjson"
  : > "$out"

  resp=$(curl -fsS -H 'Content-Type: application/json' \
    "$SOURCE_URL/$idx/_search?scroll=$SCROLL_TTL" \
    -d "{\"size\": $SCROLL_SIZE, \"query\": {\"match_all\": {}}}")

  scroll_id=$(echo "$resp" | jq -r '._scroll_id')
  total=$(echo "$resp" | jq -r '.hits.total.value // .hits.total // 0')
  echo "  total docs: $total"

  written=0
  while : ; do
    n=$(echo "$resp" | jq -r '.hits.hits | length')
    [[ "$n" == "0" ]] && break
    echo "$resp" | jq -c '.hits.hits[] |
      ({"index": {"_id": ._id}}),
      ._source
    ' >> "$out"
    written=$(( written + n ))

    resp=$(curl -fsS -H 'Content-Type: application/json' \
      "$SOURCE_URL/_search/scroll" \
      -d "{\"scroll\": \"$SCROLL_TTL\", \"scroll_id\": \"$scroll_id\"}")
    scroll_id=$(echo "$resp" | jq -r '._scroll_id')
  done

  # release scroll
  curl -fsS -X DELETE -H 'Content-Type: application/json' \
    "$SOURCE_URL/_search/scroll" \
    -d "{\"scroll_id\": [\"$scroll_id\"]}" >/dev/null || true

  echo "  wrote $written docs to $out"
  if [[ "$written" != "$total" ]]; then
    echo "WARN: wrote $written but cluster reported $total" >&2
  fi
  exported=$((exported+1))
done

echo
echo "Done. Exported $exported indices, skipped $skipped."
echo "Output dir: $EXPORT_DIR"
