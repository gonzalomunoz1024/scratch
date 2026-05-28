# Claude Code in OpenShift Dev Spaces — manifests

Browser-based VS Code per developer, running inside an OpenShift pod, with
the Claude Code extension preinstalled and wired to GitHub.

## Files

| File | What it does | Where it lives |
|---|---|---|
| `00-checluster.yaml` | The `CheCluster` CR that the Dev Spaces operator reconciles | `openshift-devspaces` namespace |
| `01-github-oauth-secret.yaml` | GitHub OAuth client id/secret for SSO + repo clone | `openshift-devspaces` namespace |
| `02-anthropic-secret.yaml` | Manual-fallback `ANTHROPIC_API_KEY` (use ESO instead for production) | each `<user>-devspaces` namespace |
| `03-devfile.yaml` | Per-repo workspace definition | root of each GitHub repo |
| `04-vllm-optional.yaml` | In-cluster model server (skip if using `api.anthropic.com`) | `ai` namespace |
| `05-eso-secret-replication.yaml` | GitOps overlay: External Secrets Operator replicates the API key to all user namespaces | `openshift-devspaces` + all `*-devspaces` |
| `06-smoke-test.yaml` | **Self-contained preflight** — creates its own `claude-preflight` namespace, Secret, and Job; walks DNS → TLS → auth → CLI → e2e | `claude-preflight` (created by the file) |

## Prerequisites

1. OpenShift 4.14+ cluster with admin access.
2. Install the **Red Hat OpenShift Dev Spaces** operator from OperatorHub. Wait
   for the operator pod in `openshift-operators` to be `Running`.
3. Register a **GitHub OAuth App** at <https://github.com/settings/developers>:
   - Homepage URL: `https://devspaces.<apps-domain>`
   - Callback URL: `https://devspaces.<apps-domain>/api/oauth/callback`

   You'll get a Client ID and Client Secret — paste them into
   `01-github-oauth-secret.yaml`.
4. Get an Anthropic API key from <https://console.anthropic.com> and paste
   it into `05-eso-secret-replication.yaml` (in `anthropic-api-key-source`).
   Skip if using vLLM.
5. Install **External Secrets Operator** from OperatorHub (or Helm). Required
   for the GitOps overlay in `05-…`.

## Step 0 — Preflight (run this FIRST, before installing anything)

`06-smoke-test.yaml` is fully self-contained. It creates its own
`claude-preflight` namespace, its own Secret, and a Job that proves a pod
on this cluster can reach Claude. No Dev Spaces, ESO, or other manifest
needs to exist for it to run.

```bash
# 1. Edit the ONE line marked  <-- EDIT THIS LINE  with your API key.
vim 06-smoke-test.yaml

# 2. Apply (creates namespace + Secret + Job in one shot).
oc apply -f 06-smoke-test.yaml

# 3. Watch the six checks run.
oc logs -n claude-preflight -f job/claude-smoke-test

# 4. Pass → tear it all down before proceeding to step 1.
oc delete -f 06-smoke-test.yaml
```

A passing run ends with `✅  SMOKE TEST PASSED`. **Only proceed to the
steps below once it passes** — every failure mode it surfaces (DNS, egress,
TLS/MITM, npm reachability, API auth) would also break Dev Spaces, just in
a much harder-to-debug way.

## Apply order

```bash
# 1. Create CheCluster (operator reconciles Dev Spaces deployment, takes ~3 min)
oc apply -f 00-checluster.yaml

# 2. GitHub OAuth — Dev Spaces will pick this up automatically
oc apply -f 01-github-oauth-secret.yaml

# 3. (Optional) Self-hosted vLLM model server
oc apply -f 04-vllm-optional.yaml

# 4. GitOps overlay — source secret + ESO replication into every user ns
oc apply -f 05-eso-secret-replication.yaml

# 5. Wait until Dev Spaces is Available
oc wait checluster/devspaces -n openshift-devspaces \
  --for=condition=Available --timeout=10m

# 6. Get the dashboard URL
oc get route -n openshift-devspaces devspaces \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

## Per-developer setup

With ESO (`05-…`) applied, the per-developer step is **zero manual work**:

1. Developer signs in → Dev Spaces auto-creates `<user>-devspaces` namespace.
2. ESO sees the new namespace match the label selector (`app.kubernetes.io/component=workspaces-namespace`) and reconciles the Secret into it within ~30 s.
3. The next workspace start in that namespace has `ANTHROPIC_API_KEY` on the env.

If ESO is unavailable, fall back to `02-anthropic-secret.yaml` applied manually
per user (`oc -n <user>-devspaces apply -f 02-…`).

## Re-running the preflight later

The same self-contained `06-smoke-test.yaml` is useful after Dev Spaces is
running too — for example, to validate a network change, debug a workspace
that can't reach Anthropic, or smoke-test from a brand-new user namespace.
Just re-apply it; it lives in its own `claude-preflight` namespace and
doesn't touch anything else.

```bash
oc delete -f 06-smoke-test.yaml --ignore-not-found
oc apply  -f 06-smoke-test.yaml
oc logs   -n claude-preflight -f job/claude-smoke-test
```

## Per-repo setup (devfile)

In each GitHub repo you want Claude-enabled:

1. Commit `03-devfile.yaml` to the repo root as `devfile.yaml`. Edit the
   `projects[0].git.remotes.origin` URL to point at that repo.
2. Commit a `.vscode/extensions.json` recommending the extension:
   ```json
   { "recommendations": ["Anthropic.claude-code"] }
   ```

## Developer flow

1. Visit the Dev Spaces dashboard URL.
2. Click **Create Workspace** and paste the GitHub repo URL — or click an
   `Open in Dev Spaces` badge linked to it.
3. Approve the GitHub OAuth prompt once.
4. Workspace pod spins up (~30–60 s), Che-Code opens in the browser, Claude
   Code installs from Open VSX, and `claude` is on `$PATH` in the terminal.
5. Use the Claude side panel or run `claude` in the terminal. Edits land in
   the cloned repo; commit and push from VS Code's Source Control panel —
   the GitHub OAuth token is already in place.

## Verification

```bash
# CheCluster healthy?
oc get checluster -n openshift-devspaces devspaces \
  -o jsonpath='{.status.chePhase}{"\n"}'   # → Active

# A specific user's workspace pod
oc get devworkspaces -n ${USER}-devspaces
oc logs -n ${USER}-devspaces deploy/workspace-<id>-deployment

# Confirm ANTHROPIC_API_KEY made it into the workspace
oc rsh -n ${USER}-devspaces deploy/workspace-<id>-deployment \
  printenv ANTHROPIC_API_KEY
```

## Tearing it all down

```bash
oc delete -f 06-smoke-test.yaml    --ignore-not-found  # also deletes the claude-preflight namespace
oc delete -f 05-eso-secret-replication.yaml
oc delete -f 04-vllm-optional.yaml --ignore-not-found
oc delete checluster devspaces -n openshift-devspaces
# Then uninstall the Dev Spaces and ESO operators from OperatorHub.
```

## References

- Dev Spaces user guide: <https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/>
- Devfile 2.2.0 schema: <https://devfile.io/docs/2.2.0/devfile-schema>
- Claude Code VS Code extension: <https://open-vsx.org/extension/Anthropic/claude-code>
- vLLM + Dev Spaces walkthrough: <https://piotrminkowski.com/2026/02/27/claude-code-on-openshift-with-vllm-and-dev-spaces/>
- RHAIIS + Claude Code: <https://developers.redhat.com/articles/2026/03/26/integrate-claude-code-red-hat-ai-inference-server-openshift>
