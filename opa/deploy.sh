#!/usr/bin/env bash
# deploy.sh — deploy the opa-polling OPA instance to OpenShift. It will fetch
# a gzipped policy bundle from a Java-served HTTP endpoint, poll for updates,
# and serve OPA's HTTP API on port 8181.
#
# Usage:
#   ./deploy.sh
# Prompts for the full bundle URL, then renders + applies the manifests in
# this directory (configmap, deployment, service, route) into the hard-coded
# namespace below.
#
# Re-runs are safe and idempotent: the deployment carries a checksum of the
# rendered ConfigMap as a pod-template annotation, so any config change
# triggers a clean rolling update with NO terminating-pod overlap on first
# deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- hard-coded knobs ------------------------------------------------------
NAMESPACE="claut-203679-primer"
POLL_MIN=20
POLL_MAX=60

# ---- preflight -------------------------------------------------------------
if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: 'oc' CLI not found in PATH." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: not logged in to a cluster. Run 'oc login ...' first." >&2
  exit 1
fi

if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "ERROR: need either 'shasum' or 'sha256sum' in PATH." >&2
  exit 1
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# ---- prompts ---------------------------------------------------------------
read -rp "Bundle endpoint URL (e.g. http://orchestrator-api.orchestrator.svc:8081/v1/utilities/registry/opa/bundle): " BUNDLE_URL
if [ -z "${BUNDLE_URL}" ]; then
  echo "ERROR: bundle URL is required." >&2
  exit 1
fi

# OPA's bundle plugin wants service.url (scheme://host[:port]) and a relative
# resource path. Split the full URL accordingly.
case "${BUNDLE_URL}" in
  http://*|https://*) ;;
  *) echo "ERROR: bundle URL must start with http:// or https://" >&2; exit 1 ;;
esac
PROTO="${BUNDLE_URL%%://*}"
REST="${BUNDLE_URL#*://}"
HOST="${REST%%/*}"
PATH_PART="${REST#*/}"
if [ "${PATH_PART}" = "${REST}" ] || [ -z "${PATH_PART}" ]; then
  echo "ERROR: URL must include a path to the bundle, e.g. http://host:8081/v1/utilities/registry/opa/bundle" >&2
  exit 1
fi
SERVICE_URL="${PROTO}://${HOST}"
RESOURCE="${PATH_PART}"

echo
echo "About to deploy OPA with:"
echo "  namespace:       ${NAMESPACE}"
echo "  service.url:     ${SERVICE_URL}"
echo "  bundle.resource: ${RESOURCE}"
echo "  full bundle URL: ${SERVICE_URL}/${RESOURCE}"
echo "  polling:         min=${POLL_MIN}s max=${POLL_MAX}s"
echo
read -rp "Proceed? [y/N]: " CONFIRM
case "${CONFIRM}" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

# ---- namespace -------------------------------------------------------------
if ! oc get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Creating namespace ${NAMESPACE}..."
  oc create namespace "${NAMESPACE}"
fi

# ---- render ----------------------------------------------------------------
# Pure-bash templater: literal ${NAME} → value. No regex, no escaping
# pitfalls, no external dependency.
render() {
  local content
  content=$(<"$1")
  content="${content//\$\{SERVICE_URL\}/${SERVICE_URL}}"
  content="${content//\$\{RESOURCE\}/${RESOURCE}}"
  content="${content//\$\{POLL_MIN\}/${POLL_MIN}}"
  content="${content//\$\{POLL_MAX\}/${POLL_MAX}}"
  content="${content//\$\{CONFIG_HASH\}/${CONFIG_HASH:-}}"
  printf '%s\n' "$content"
}

# Step 1: render the ConfigMap and hash its contents. The hash goes onto the
# Deployment's pod template as an annotation, so any config change forces a
# rolling update via plain 'oc apply'.
RENDERED_CM="$(render "${SCRIPT_DIR}/configmap.yaml")"
CONFIG_HASH="$(printf '%s' "${RENDERED_CM}" | sha256)"
export CONFIG_HASH

# Step 2: render everything else now that CONFIG_HASH is known.
RENDERED_DEPLOY="$(render "${SCRIPT_DIR}/deployment.yaml")"
RENDERED_SVC="$(<"${SCRIPT_DIR}/service.yaml")"
RENDERED_ROUTE="$(<"${SCRIPT_DIR}/route.yaml")"

# ---- validate (server-side dry run) ----------------------------------------
echo "Validating manifests against the API server..."
{
  printf '%s\n---\n%s\n---\n%s\n---\n%s\n' \
    "${RENDERED_CM}" "${RENDERED_DEPLOY}" "${RENDERED_SVC}" "${RENDERED_ROUTE}"
} | oc apply -n "${NAMESPACE}" --dry-run=server -f - >/dev/null

# ---- apply -----------------------------------------------------------------
echo "Applying manifests..."
{
  printf '%s\n---\n%s\n---\n%s\n---\n%s\n' \
    "${RENDERED_CM}" "${RENDERED_DEPLOY}" "${RENDERED_SVC}" "${RENDERED_ROUTE}"
} | oc apply -n "${NAMESPACE}" -f -

# ---- wait for rollout ------------------------------------------------------
echo
echo "Waiting for rollout..."
if ! oc -n "${NAMESPACE}" rollout status deployment/opa-polling --timeout=180s; then
  echo "Rollout did not complete; recent pod state:"
  oc -n "${NAMESPACE}" get pods -l app=opa-polling -o wide
  echo
  echo "Recent logs:"
  oc -n "${NAMESPACE}" logs deploy/opa-polling --tail=80 || true
  exit 1
fi

# ---- verify via the Route --------------------------------------------------
# Prove OPA is up AND that it successfully fetched the bundle from the Java
# endpoint by:
#   1. polling /health?bundles until 200 (OPA only returns 200 once at least
#      one bundle has been activated — i.e. downloaded + parsed)
#   2. dumping /v1/policies via the Route and printing each rego module's raw
#      source. These policies came from the bundle endpoint, not from disk.

ROUTE_HOST="$(oc -n "${NAMESPACE}" get route opa-polling -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [ -z "${ROUTE_HOST}" ]; then
  echo "ERROR: Route opa-polling has no host yet — cannot verify." >&2
  exit 1
fi
ROUTE_URL="https://${ROUTE_HOST}"

echo
echo "Verifying via Route ${ROUTE_URL} ..."

# 1) wait for /health?bundles to flip to 200
HEALTH_CODE="000"
for i in $(seq 1 30); do
  HEALTH_CODE="$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 5 "${ROUTE_URL}/health?bundles" || echo "000")"
  if [ "${HEALTH_CODE}" = "200" ]; then
    echo "  attempt ${i}: /health?bundles → 200 (bundle activated)"
    break
  fi
  echo "  attempt ${i}: /health?bundles → ${HEALTH_CODE} (waiting for first bundle fetch)"
  sleep 2
done

if [ "${HEALTH_CODE}" != "200" ]; then
  echo "ERROR: OPA never reported a healthy bundle. Last /health?bundles → ${HEALTH_CODE}" >&2
  echo "Recent OPA logs (this almost certainly shows the bundle-fetch error):" >&2
  oc -n "${NAMESPACE}" logs deploy/opa-polling --tail=120 || true
  exit 1
fi

# 2) fetch the policies and print them so there's visible evidence
echo
echo "Policies served by OPA (fetched dynamically from ${SERVICE_URL}/${RESOURCE}):"
echo "================================================================"
POLICIES_JSON="$(curl -sS -k --max-time 10 "${ROUTE_URL}/v1/policies")"

if command -v jq >/dev/null 2>&1; then
  COUNT="$(printf '%s' "${POLICIES_JSON}" | jq '.result | length')"
  echo "  policy count: ${COUNT}"
  echo
  printf '%s' "${POLICIES_JSON}" | jq -r '
    .result[]
    | "----- policy id: \(.id) -----\n\(.raw)\n"
  '
elif command -v python3 >/dev/null 2>&1; then
  printf '%s' "${POLICIES_JSON}" | python3 -c '
import sys, json
data = json.load(sys.stdin)
items = data.get("result", [])
print(f"  policy count: {len(items)}\n")
for p in items:
    print(f"----- policy id: {p.get(\"id\")} -----")
    print(p.get("raw", "<no raw source>"))
    print()
'
else
  echo "  (jq and python3 both missing — printing raw JSON)"
  printf '%s\n' "${POLICIES_JSON}"
fi
echo "================================================================"

# ---- summary ---------------------------------------------------------------
echo
echo "OPA deployed and verified."
echo "  Route:      ${ROUTE_URL}"
echo "  Health:     ${ROUTE_URL}/health?bundles"
echo "  Policies:   ${ROUTE_URL}/v1/policies"
echo "  Data:       ${ROUTE_URL}/v1/data"
echo "  In-cluster: http://opa-polling.${NAMESPACE}.svc.cluster.local:8181"
echo "  Logs:       oc -n ${NAMESPACE} logs -f deploy/opa-polling"
