#!/usr/bin/env bash
# run.sh — run OPA on this machine in bundle/fetch mode, pulling a gzipped
# policy bundle from a (typically locally-running) Java endpoint. Mirrors the
# OpenShift Deployment in ../opa, minus the Kubernetes plumbing.
#
# Usage:
#   ./run.sh                # prompts for the bundle URL
#   ./run.sh <bundle-url>   # non-interactive
#
# Assumes the `opa` binary is already on $PATH. After OPA starts, leave this
# terminal open — OPA runs in the foreground and prints decision/status logs.
# Hit Ctrl-C to stop. To verify it's fetching policies, in a second terminal:
#   curl -s http://localhost:8181/health?bundles      # → 200 once activated
#   curl -s http://localhost:8181/v1/policies | jq .  # → fetched policies

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- hard-coded knobs (parallel to ../opa/deploy.sh) -----------------------
POLL_MIN=20
POLL_MAX=60
ADDR="localhost:8181"
DEFAULT_URL="http://localhost:8081/v1/utilities/registry/opa/bundle"

# ---- preflight -------------------------------------------------------------
if ! command -v opa >/dev/null 2>&1; then
  echo "ERROR: 'opa' not found in PATH. Install OPA first:" >&2
  echo "  brew install opa            # macOS" >&2
  echo "  # or: https://www.openpolicyagent.org/docs/latest/#running-opa" >&2
  exit 1
fi

# ---- input -----------------------------------------------------------------
if [ "$#" -ge 1 ]; then
  BUNDLE_URL="$1"
else
  read -rp "Bundle endpoint URL [${DEFAULT_URL}]: " BUNDLE_URL
  BUNDLE_URL="${BUNDLE_URL:-${DEFAULT_URL}}"
fi

case "${BUNDLE_URL}" in
  http://*|https://*) ;;
  *) echo "ERROR: bundle URL must start with http:// or https://" >&2; exit 1 ;;
esac

PROTO="${BUNDLE_URL%%://*}"
REST="${BUNDLE_URL#*://}"
HOST="${REST%%/*}"
PATH_PART="${REST#*/}"
if [ "${PATH_PART}" = "${REST}" ] || [ -z "${PATH_PART}" ]; then
  echo "ERROR: URL must include a path, e.g. http://localhost:8081/v1/utilities/registry/opa/bundle" >&2
  exit 1
fi
SERVICE_URL="${PROTO}://${HOST}"
RESOURCE="${PATH_PART}"

# ---- write config.yaml -----------------------------------------------------
CONFIG="${SCRIPT_DIR}/config.yaml"
cat > "${CONFIG}" <<EOF
services:
  - name: bundle-service
    url: ${SERVICE_URL}
    # Skip TLS verification — locally the Java endpoint may be plain http
    # (no-op) or a self-signed https. Drop this and set tls.ca_cert when
    # running against a trusted endpoint.
    allow_insecure_tls: true

bundles:
  main:
    service: bundle-service
    resource: ${RESOURCE}
    polling:
      min_delay_seconds: ${POLL_MIN}
      max_delay_seconds: ${POLL_MAX}

decision_logs:
  console: true

status:
  console: true
EOF

echo
echo "Starting OPA with:"
echo "  bundle URL:  ${SERVICE_URL}/${RESOURCE}"
echo "  polling:     min=${POLL_MIN}s max=${POLL_MAX}s"
echo "  listen:      http://${ADDR}"
echo "  rendered:    ${CONFIG}"
echo "  opa version: $(opa version | awk '/^Version/ {print $2; exit}')"
echo

# ---- run -------------------------------------------------------------------
exec opa run \
  --server \
  --addr="${ADDR}" \
  --config-file="${CONFIG}" \
  --shutdown-grace-period=5 \
  --shutdown-wait-period=2 \
  --log-level=info
