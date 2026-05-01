#!/usr/bin/env bash
# 01-start-local.sh — bring up the local "source" OpenSearch from
# the recovered PVC data sitting in ./os-data.
#
# Assumes:
#   - ./os-data/nodes/0/indices/<uuid>/...  already exists
#     (i.e. you've already copied/extracted the recovered PVC contents
#     so that `nodes/` is directly under `os-data/`).
#   - Docker is running.
#
# This script:
#   1. Sanity-checks the data layout.
#   2. chowns os-data to UID 1000 via a throwaway alpine container
#      (idempotent; safe to re-run).
#   3. docker compose up -d
#   4. Waits for cluster health and lists indices.

set -euo pipefail

cd "$(dirname "$0")"

# ---- 1. sanity-check layout -------------------------------------------------
if [[ ! -d ./os-data/nodes/0/indices ]]; then
  echo "ERROR: expected ./os-data/nodes/0/indices/ to exist." >&2
  echo "       Current ./os-data layout:" >&2
  ls -la ./os-data 2>/dev/null || echo "       (./os-data does not exist)" >&2
  exit 1
fi

idx_count=$(find ./os-data/nodes/0/indices -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
echo "Found $idx_count index directories under ./os-data/nodes/0/indices/"

# ---- 2. fix ownership (idempotent) ------------------------------------------
echo "Ensuring ./os-data is owned by UID 1000 (opensearch user inside container)..."
docker run --rm \
  -v "$PWD/os-data:/data" \
  --user 0:0 \
  alpine:3 \
  sh -c 'chown -R 1000:1000 /data && chmod -R u+rwX /data'

# ---- 3. start the stack -----------------------------------------------------
echo "Bringing up the local source cluster..."
docker compose up -d

# ---- 4. wait for health -----------------------------------------------------
echo -n "Waiting for cluster to become reachable"
for i in $(seq 1 60); do
  if curl -fsS http://localhost:9200/_cluster/health >/dev/null 2>&1; then
    echo
    break
  fi
  echo -n "."
  sleep 2
  if [[ $i -eq 60 ]]; then
    echo
    echo "ERROR: cluster never came up. Logs:" >&2
    docker compose logs --tail=50 opensearch >&2
    exit 1
  fi
done

echo
echo "Cluster health:"
curl -sS http://localhost:9200/_cluster/health | sed 's/,/,\n  /g'

echo
echo "Indices visible to the cluster (expand_wildcards=all):"
curl -sS 'http://localhost:9200/_cat/indices?v&expand_wildcards=all'

echo
echo "Done. If your 14 indices show above, you're ready for 02-export.sh."
echo "If they DON'T show, check logs with:  docker compose logs opensearch | tail -100"
