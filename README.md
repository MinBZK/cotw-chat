# COTW

**Coalition of the Willing** — GitOps repository that deploys a self-hosted Matrix chat solution to Kubernetes with [Argo CD](https://argo-cd.readthedocs.io/).

> [!NOTE]
> This repository is still in development. Structure and contents may change without notice.

## Components

Workloads (`apps/`):

* Element Web — Matrix web client
* Synapse — Matrix homeserver
* Matrix Authentication Service (MAS)
* Keycloak — identity provider (OIDC); any other IdP can be substituted
* Valkey — cache

Platform operators (`platform/`):

* cert-manager — certificates and issuers
* CloudNativePG — the operator behind the `Cluster` CRs the workloads own; one per database
* external-secrets — installed, not yet wired to a backend
* Gateway API — CRDs only, pulled from the upstream release asset (SIG Network ships no chart)
* trust-manager — CA bundle distribution for cert-manager

Excluded for now:

* Element Call
* LiveKit

## How it deploys

Argo CD is the only consumer of this repo; there is nothing to build or run locally.

* `bootstrap/` — applied to a cluster **once, by hand**: both AppProjects (`cotw`, `cotw-platform`) and the root Application (app-of-apps).
* `clusters/<cluster>/` — two ApplicationSets per cluster:
  * `app-applicationset.yaml` → one Application per workload, from `apps/{{.product}}/overlays/<cluster>`
  * `platform-applicationset.yaml` → one Application per operator, from `platform/{{.product}}`
* `apps/<product>/` and `platform/<operator>/` — a kustomize project that inflates a pinned Helm chart, plus any extra manifests.

Both product lists are explicit: creating a directory does nothing until you add an element to the ApplicationSets.

Clusters: `odcnoord` (OpenShift, HAProxy Ingress), `odcrijswijk` (Rancher, Gateway API). Both use destination namespace `cotw-{{.product}}`.

Once bootstrapped, pushes to `main` deploy. Note the two sync policies differ: workloads use `prune: true`, operators use `prune: false` so that dropping an operator can never cascade-delete its CRDs. Both sets use `applicationsSync: create-update`, which means **removing an element from a list does not delete its Application** — uninstalling is a manual step.

## Verifying locally

```bash
./scripts/render.sh          # renders every product in every cluster
shellcheck scripts/render.sh
```

Output goes to `render/<cluster>/<set>/<product>.yaml`. The NOTES column flags namespace problems — read it before pushing.

## Secrets

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using age — see `.sops.yaml` for recipients. Only `data`/`stringData` fields are encrypted, with `mac_only_encrypted: true`.

```bash
age-keygen -o keys.txt       # your own key
```

Add your public key to `.sops.yaml`, then ask someone who already has access to re-encrypt the existing secrets. The private key lives in `keys.txt` (gitignored, mode 0600) — treat it as the only copy until you have a recovery plan.

```bash
SOPS_AGE_KEY_FILE=$PWD/keys.txt sops --decrypt apps/keycloak/base/secret.yaml
sops --set '["stringData"]["key"] "value"' <file>
```

Encrypted today: `apps/keycloak/base/secret.yaml`, `apps/matrix-stack/base/secret-synapse.yaml`, `apps/matrix-stack/base/secret-mas.yaml`.

## Argo CD

The repo-server needs:

```text
--enable-helm --load-restrictor LoadRestrictionsNone
```

plus the age key available as `SOPS_AGE_KEY_FILE`, and outbound access to GitHub — `platform/gateway-api/` pulls an upstream release asset at render time.

## Cluster differences

### ODC-Noord

OpenShift, `restricted-v2` SCC, HAProxy Ingress. SCC rejects hardcoded UIDs, so every chart's `runAsUser`/`runAsGroup`/`fsGroup` is nulled out and the namespace assigns them instead.

### ODC-Rijswijk

Rancher with Gateway API.

## Known gaps

Deliberately not done yet:

* **TLS is off** (`ingress.tlsEnabled: false`) — no cert-manager issuer or `tlsSecret` is wired up. Matrix federation over plain HTTP will not work.
* **Placeholder hostnames** — `matrix.example.com` and its subdomains deploy on every push to `main`.
* **No environment split** — one `values.yaml` per product serves both clusters. `matrix-stack` emits `Ingress` only, so ODC-Rijswijk gets nothing routable, while also receiving SCC nulling it does not need.
* **No backups** for any CloudNativePG `Cluster`.
* **SOPS MAC vs kustomize** — kustomize alphabetises keys and SOPS' MAC is order-sensitive, so `sops --decrypt` on rendered output fails even though the source files decrypt fine. Argo verifies the MAC, so this is expected to block the three secrets on first sync. Deferred; see `AGENTS.md`.
* **No NetworkPolicies, no ServiceMonitors, no image digest pinning**, and a single age recipient with no rotation procedure.