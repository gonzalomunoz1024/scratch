#!/usr/bin/env bash
# diagnose-egress.sh — read-only diagnostic for Claude Code connectivity
# from inside an OpenShift cluster. Captures everything needed to figure
# out *why* TCP/443 to api.anthropic.com is blocked.
#
# Usage:
#   ./diagnose-egress.sh                       # defaults to claude-preflight ns
#   ./diagnose-egress.sh some-other-namespace
#
# Then paste the FULL output (everything between the BEGIN and END markers)
# back to the assistant.
#
# What it does (none of these mutate cluster state except for one short-lived
# diagnostic Job in $NS, which is auto-deleted at the end):
#   1. Cluster identity   — version, network plugin
#   2. Cluster proxy      — `oc get proxy/cluster`
#   3. Egress firewalls   — OVN-K EgressFirewall + legacy SDN EgressNetworkPolicy
#   4. NetworkPolicies    — namespace + cluster-wide
#   5. SCC / quota        — anything that would block the test pod
#   6. From-pod tests     — runs a Job that probes DNS, TCP, TLS, HTTPS with
#                           and without the cluster proxy, against
#                           api.anthropic.com, registry.npmjs.org, and
#                           open-vsx.org (the three egress targets the full
#                           Dev Spaces stack needs).
#   7. Summary hypothesis — first plausible cause given the evidence.

set -uo pipefail

NS="${1:-claude-preflight}"
JOB="claude-egress-debug"
IMG="registry.access.redhat.com/ubi9/nodejs-20:latest"
TARGETS=("api.anthropic.com" "registry.npmjs.org" "open-vsx.org")

# ---- helpers ---------------------------------------------------------------
hr()   { printf '\n%s\n' "================================================================"; }
hdr()  { hr; printf ' %s\n' "$*"; hr; }
sub()  { printf '\n--- %s ---\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if ! have oc; then
  echo "ERROR: 'oc' CLI not found in PATH. Install the OpenShift client first." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: not logged in to a cluster. Run 'oc login ...' first." >&2
  exit 1
fi

trap 'oc -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

# ---- header ----------------------------------------------------------------
hdr "BEGIN CLAUDE EGRESS DIAGNOSTIC"
echo "timestamp:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "namespace:    $NS"
echo "oc user:      $(oc whoami 2>/dev/null || echo unknown)"
echo "oc server:    $(oc whoami --show-server 2>/dev/null || echo unknown)"
echo "targets:      ${TARGETS[*]}"

# ---- 1. cluster identity ---------------------------------------------------
hdr "1. CLUSTER IDENTITY"
oc version 2>&1 | sed 's/^/  /'
sub "network plugin"
oc get network.config/cluster -o jsonpath='{.status.networkType}{"\n"}' 2>&1 \
  | sed 's/^/  /' || echo "  (could not read network.config/cluster — likely not cluster-admin)"
sub "cluster version (channel)"
oc get clusterversion -o jsonpath='{.items[0].status.desired.version}{"\n"}' 2>&1 \
  | sed 's/^/  /' || echo "  (no permission)"

# ---- 2. cluster-wide proxy -------------------------------------------------
hdr "2. CLUSTER-WIDE PROXY (proxy/cluster)"
PROXY_HTTP=$(oc get proxy/cluster -o jsonpath='{.status.httpProxy}'  2>/dev/null || true)
PROXY_HTTPS=$(oc get proxy/cluster -o jsonpath='{.status.httpsProxy}' 2>/dev/null || true)
PROXY_NO=$(oc get proxy/cluster -o jsonpath='{.status.noProxy}'    2>/dev/null || true)
PROXY_CA=$(oc get proxy/cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || true)

echo "  status.httpProxy:   ${PROXY_HTTP:-<none>}"
echo "  status.httpsProxy:  ${PROXY_HTTPS:-<none>}"
echo "  status.noProxy:     ${PROXY_NO:-<none>}"
echo "  spec.trustedCA:     ${PROXY_CA:-<none>}"
sub "full proxy/cluster yaml"
oc get proxy/cluster -o yaml 2>&1 | sed 's/^/  /'

# ---- 3. egress firewalls ---------------------------------------------------
hdr "3. EGRESS FIREWALLS"
sub "OVN-K EgressFirewall (cluster-wide list)"
oc get egressfirewall -A 2>&1 | sed 's/^/  /' || true
sub "OVN-K EgressFirewall in $NS (full yaml)"
oc get egressfirewall -n "$NS" -o yaml 2>&1 | sed 's/^/  /' || true

sub "SDN EgressNetworkPolicy (legacy)"
oc get egressnetworkpolicy -A 2>&1 | sed 's/^/  /' || true

sub "AdminNetworkPolicy / BaselineAdminNetworkPolicy (4.14+)"
oc get adminnetworkpolicy 2>&1 | sed 's/^/  /' || true
oc get baselineadminnetworkpolicy 2>&1 | sed 's/^/  /' || true

# ---- 4. NetworkPolicies ----------------------------------------------------
hdr "4. NETWORKPOLICIES"
sub "all namespaces (names only)"
oc get networkpolicy -A 2>&1 | sed 's/^/  /' || true
sub "in $NS (full yaml)"
oc get networkpolicy -n "$NS" -o yaml 2>&1 | sed 's/^/  /' || true

# ---- 5. SCC / quota that could affect the test pod -------------------------
hdr "5. SCC / RESOURCEQUOTA / LIMITRANGE in $NS"
sub "resourcequota"
oc get resourcequota -n "$NS" -o yaml 2>&1 | sed 's/^/  /' || true
sub "limitrange"
oc get limitrange -n "$NS" -o yaml 2>&1 | sed 's/^/  /' || true
sub "can I create a Job here?"
oc auth can-i create jobs -n "$NS" 2>&1 | sed 's/^/  /'

# ---- 6. From-pod tests via a one-shot Job ----------------------------------
hdr "6. FROM-POD CONNECTIVITY TESTS"

if ! oc get ns "$NS" >/dev/null 2>&1; then
  echo "  namespace '$NS' does not exist; skipping in-pod tests."
  echo "  Create it (oc new-project $NS) and re-run."
else
  echo "  Submitting diagnostic Job '$JOB' to namespace '$NS'..."

  # Build the in-pod script. It probes each target across DNS, raw TCP,
  # TLS, plain HTTPS, and HTTPS-via-cluster-proxy (if one is configured).
  POD_SCRIPT=$(cat <<'POD'
set -u
TARGETS=(api.anthropic.com registry.npmjs.org open-vsx.org)

hr(){ printf '\n----------------------------------------------------------------\n'; }

echo "pod uname:       $(uname -a)"
echo "pod hostname:    $(hostname)"
echo "pod namespace:   $(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null)"
echo "pod default rt:  $(ip route 2>/dev/null | awk '/^default/ {print; exit}')"
echo
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf
echo
echo "--- env: proxy vars seen by this pod ---"
env | grep -iE '^(http|https|no)_proxy=' | sort || echo "(none set)"

for T in "${TARGETS[@]}"; do
  hr
  echo "TARGET: $T"

  echo "[A] DNS via getent:"
  getent hosts "$T" 2>&1 | sed 's/^/    /' || echo "    DNS lookup failed"

  echo "[B] raw TCP/443 (direct, no proxy):"
  if timeout 8 bash -c "</dev/tcp/$T/443" 2>/dev/null; then
    echo "    OK — direct TCP/443 to $T succeeded"
  else
    echo "    FAIL — direct TCP/443 to $T blocked (egress firewall, NetPol, or proxy required)"
  fi

  echo "[C] TLS handshake (direct, no proxy):"
  echo | timeout 10 openssl s_client -connect "$T:443" -servername "$T" -brief 2>&1 \
    | sed 's/^/    /' | head -20

  echo "[D] HTTPS GET / (direct, no proxy):"
  curl -sS --max-time 15 -o /dev/null -w '    HTTP %{http_code}  (connect=%{time_connect}s  total=%{time_total}s)\n' \
    "https://$T/" 2>&1 | sed 's/^/    /' || echo "    curl direct failed"

  if [ -n "${HTTPS_PROXY:-}${https_proxy:-}" ]; then
    PX="${HTTPS_PROXY:-${https_proxy}}"
    echo "[E] HTTPS GET / VIA CLUSTER PROXY ($PX):"
    curl -sS --max-time 15 -x "$PX" -o /dev/null \
      -w '    HTTP %{http_code}  (connect=%{time_connect}s  total=%{time_total}s)\n' \
      "https://$T/" 2>&1 | sed 's/^/    /' || echo "    curl via proxy failed"
  else
    echo "[E] HTTPS GET via proxy: SKIPPED (no HTTPS_PROXY env set in this pod)"
  fi
done

hr
echo "DONE"
POD
)

  # Inject cluster proxy values into the pod if any were detected, plus a
  # base64-encoded copy of the in-pod script so we don't fight YAML quoting.
  POD_SCRIPT_B64=$(printf %s "$POD_SCRIPT" | base64 | tr -d '\n')

  cat <<EOF | oc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: probe
        image: $IMG
        env:
        - name: HTTP_PROXY
          value: "${PROXY_HTTP}"
        - name: HTTPS_PROXY
          value: "${PROXY_HTTPS}"
        - name: NO_PROXY
          value: "${PROXY_NO}"
        - name: SCRIPT_B64
          value: "${POD_SCRIPT_B64}"
        command: ["/bin/bash","-c"]
        args: ["echo \$SCRIPT_B64 | base64 -d | bash"]
        resources:
          requests: { cpu: 100m, memory: 256Mi }
          limits:   { cpu: "1",  memory: 512Mi }
EOF

  echo "  Waiting up to 3 minutes for Job to complete..."
  oc -n "$NS" wait --for=condition=complete --timeout=180s "job/$JOB" >/dev/null 2>&1 \
    || oc -n "$NS" wait --for=condition=failed   --timeout=10s  "job/$JOB" >/dev/null 2>&1 \
    || true

  sub "Job status"
  oc -n "$NS" get job "$JOB" -o wide 2>&1 | sed 's/^/  /'

  sub "Pod status"
  oc -n "$NS" get pod -l job-name="$JOB" -o wide 2>&1 | sed 's/^/  /'

  sub "Pod logs"
  oc -n "$NS" logs "job/$JOB" --tail=-1 2>&1 | sed 's/^/  /'

  sub "Pod events (last 20)"
  POD=$(oc -n "$NS" get pod -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "${POD:-}" ]; then
    oc -n "$NS" describe pod "$POD" 2>&1 | awk '/Events:/,0' | tail -25 | sed 's/^/  /'
  fi
fi

# ---- 7. summary hypothesis -------------------------------------------------
hdr "7. FIRST-PASS HYPOTHESIS"
{
  if [ -n "$PROXY_HTTPS" ]; then
    echo "* Cluster has a proxy at $PROXY_HTTPS — the smoke test pod must"
    echo "  use it. Either set HTTPS_PROXY in the Job manifest or add the"
    echo "  config.openshift.io/inject-proxy annotation."
  fi
  if oc get egressfirewall -A 2>/dev/null | grep -q .; then
    echo "* EgressFirewall objects exist — check their allowlist for"
    echo "  api.anthropic.com, registry.npmjs.org, open-vsx.org."
  fi
  if oc get networkpolicy -n "$NS" 2>/dev/null | grep -qv 'No resources'; then
    echo "* NetworkPolicies exist in $NS — confirm none default-deny egress."
  fi
  if [ -z "$PROXY_HTTPS" ] \
     && ! oc get egressfirewall -A 2>/dev/null | grep -q . \
     && ! oc get networkpolicy -A 2>/dev/null | grep -qv 'No resources'; then
    echo "* No cluster proxy, no EgressFirewall, no NetworkPolicy detected."
    echo "  Block is likely below Kubernetes — node security group / NAT GW /"
    echo "  upstream corporate firewall. Confirm with your platform team."
  fi
} | sed 's/^/  /'

hdr "END CLAUDE EGRESS DIAGNOSTIC"
