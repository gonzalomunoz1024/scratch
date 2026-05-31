#!/usr/bin/env bash
# deploy.sh — deploy an OPA instance to OpenShift that pulls a bundle (tar.gz)
# from a Java-served HTTP endpoint.
#
# Usage:
#   ./deploy.sh
# Prompts for the bundle URL and namespace, then applies the manifests in
# this directory (configmap, deployment, service, route).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- preflight -------------------------------------------------------------
if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: 'oc' CLI not found in PATH." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: not logged in to a cluster. Run 'oc login ...' first." >&2
  exit 1
fi

# ---- prompts ---------------------------------------------------------------
# The Java service exposes the bundle at a fixed path; we only need the base
# URL of the service (e.g. an in-cluster Service or an OpenShift Route).
DEFAULT_BUNDLE_PATH="v1/utilities/registry/opa/bundle"

read -rp "Java service base URL (e.g. http://orchestrator-api.orchestrator.svc:8081): " SERVICE_URL
if [ -z "${SERVICE_URL}" ]; then
  echo "ERROR: service URL is required." >&2
  exit 1
fi
# Strip trailing slash so concatenation is clean.
SERVICE_URL="${SERVICE_URL%/}"

read -rp "Bundle path [${DEFAULT_BUNDLE_PATH}]: " RESOURCE
RESOURCE="${RESOURCE:-${DEFAULT_BUNDLE_PATH}}"
# Strip any leading slash — OPA expects a relative resource.
RESOURCE="${RESOURCE#/}"

read -rp "OpenShift namespace [opa]: " NAMESPACE
NAMESPACE="${NAMESPACE:-opa}"

read -rp "Bundle polling min delay seconds [60]: " POLL_MIN
POLL_MIN="${POLL_MIN:-60}"

read -rp "Bundle polling max delay seconds [120]: " POLL_MAX
POLL_MAX="${POLL_MAX:-120}"

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

# ---- render + apply --------------------------------------------------------
export SERVICE_URL RESOURCE POLL_MIN POLL_MAX

render() {
  # Substitute only the variables we export; leave any other $... alone.
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${SERVICE_URL} ${RESOURCE} ${POLL_MIN} ${POLL_MAX}' < "$1"
  else
    sed -e "s|\${SERVICE_URL}|${SERVICE_URL}|g" \
        -e "s|\${RESOURCE}|${RESOURCE}|g" \
        -e "s|\${POLL_MIN}|${POLL_MIN}|g" \
        -e "s|\${POLL_MAX}|${POLL_MAX}|g" \
        "$1"
  fi
}

for f in configmap.yaml deployment.yaml service.yaml route.yaml; do
  echo "Applying ${f}..."
  render "${SCRIPT_DIR}/${f}" | oc apply -n "${NAMESPACE}" -f -
done

# Force a rollout so an updated ConfigMap is picked up on re-runs.
oc -n "${NAMESPACE}" rollout restart deployment/opa >/dev/null 2>&1 || true

echo
echo "Waiting for rollout..."
oc -n "${NAMESPACE}" rollout status deployment/opa --timeout=180s || {
  echo "Rollout did not complete; recent pod state:"
  oc -n "${NAMESPACE}" get pods -l app=opa -o wide
  oc -n "${NAMESPACE}" logs deploy/opa --tail=50 || true
  exit 1
}

ROUTE_HOST="$(oc -n "${NAMESPACE}" get route opa -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo
echo "OPA deployed."
if [ -n "${ROUTE_HOST}" ]; then
  echo "  Route:   https://${ROUTE_HOST}"
  echo "  Health:  https://${ROUTE_HOST}/health?bundles"
fi
echo "  In-cluster: http://opa.${NAMESPACE}.svc.cluster.local:8181"
