# AGENTS.md

GitOps repository for the COTW Matrix stack, deployed exclusively by Argo CD. There is nothing to build or run locally — the output is the manifests Argo CD syncs from `main`.

## Layout

- `bootstrap/` — the only manifests applied to a cluster **by hand**:
  - `appproject.yaml` — AppProject `cotw` (workloads).
  - `appproject-platform.yaml` — AppProject `cotw-platform` (operators; the only place cluster-scoped resources are allowed).
  - `odcnoord.yaml`, `odcrijswijk.yaml` — root Application (app-of-apps) per cluster. Globs `clusters/<cluster>/**/*-applicationset.yaml`.
- `clusters/<cluster>/app-applicationset.yaml` — generates one Application per workload from `apps/{{.product}}/overlays/<cluster>`.
- `clusters/<cluster>/platform-applicationset.yaml` — generates one Application per operator from `platform/{{.product}}`.
- `apps/<product>/` — workloads: `keycloak`, `matrix-stack`, `valkey`. Each has `base/` (the kustomize project inflating the chart) and `overlays/<cluster>/` (sets `namespace:` and any per-cluster patches; Argo points here).
- `platform/<operator>/` — operators: `cert-manager`, `cloudnative-pg`, `external-secrets`, `gateway-api`, `trust-manager`.
- `scripts/render.sh` — local render of every product in every cluster's ApplicationSets.

Both ApplicationSet lists are explicit: creating `apps/foo/` or `platform/foo/` does nothing until an element is added.

Clusters: `odcnoord` (OpenShift, restricted SCC, HAProxy Ingress), `odcrijswijk` (Rancher, Gateway API). Destination namespace is `cotw-{{.product}}` in both.

## Render mechanism

Each product is a **kustomize project that inflates a Helm chart** — not a Helm chart directly:

```yaml
# <product>/kustomization.yaml
helmCharts:
  - name: <chart>
    repo: <oci:// or https:// index URL>
    version: <pinned>
    releaseName: <name>
    valuesFile: values.yaml
```

`Chart.yaml` at the product level is **not** how Helm is detected here; nothing in this repo uses that. `values.yaml` must be plain YAML.

- Extra manifests go in `resources:`, cross-cutting edits in `patches:`.
- `platform/gateway-api/` has no `helmCharts` at all — SIG Network ships no chart by design (kubernetes-sigs/gateway-api#4809), so it pulls an immutable release asset URL as a `resources:` entry.

## Sync policy

| | app set | platform set |
|---|---|---|
| project | `cotw` | `cotw-platform` |
| `prune` | `true` | **`false`** — dropping an operator must never cascade-delete its CRDs |
| `selfHeal` | `true` | `true` |
| `applicationsSync` | `create-update` | `create-update` |
| `ServerSideApply` | `false` | `true` |
| `CreateNamespace` | — | `true` |
| `SkipDryRunOnMissingResource` | `true` | `true` |
| retry | `limit: 10`, `maxDuration: 15m` | same |

**`applicationsSync: create-update` means removing an element does NOT delete its Application** — it keeps syncing whatever is left. Uninstalling is a manual step on both sets. This contradicts what earlier revisions of this file and the README claimed.

`SkipDryRunOnMissingResource` + the retry budget is the only ordering guarantee between Applications: there is no cross-Application ordering, so a workload may sync before its CRD or dependency exists and will converge on retries.

Within an Application, ordering uses `argocd.argoproj.io/sync-wave` (see `patches:` in `apps/keycloak` and `apps/matrix-stack`: `-2` DB credentials, `-1` CNPG `Cluster`, `0` everything else). Argo's built-in `postgresql.cnpg.io/Cluster` health check (Argo CD 3.4+) holds wave `-1` until Postgres is actually ready.

## Secrets

SOPS with age. `.sops.yaml` encrypts only `data|stringData` with `mac_only_encrypted: true`, to a single recipient. The private key lives in `keys.txt` (gitignored, mode 0600).

- Encrypt: `sops --encrypt --in-place <file>`
- Read: `SOPS_AGE_KEY_FILE=$PWD/keys.txt sops --decrypt <file>`
- Changing a value: `sops --set '["stringData"]["key"] "value"' <file>` — do **not** hand-edit ciphertext or decrypt/re-encrypt out of band.

Encrypted files today: `apps/keycloak/base/secret.yaml`, `apps/matrix-stack/base/secret-synapse.yaml`, `apps/matrix-stack/base/secret-mas.yaml`.

## Verify before pushing

```bash
./scripts/render.sh          # exit 0 required
shellcheck scripts/render.sh
```

`render.sh` reads every `clusters/<cluster>/*-applicationset.yaml`, derives the source path from each ApplicationSet's own `spec.source.path`, and writes `render/<cluster>/<set>/<product>.yaml`. Its NOTES column reports namespace problems — read it.

## Rules

- Follow `.editorconfig`: 2-space indent, LF.
- ApplicationSets use `goTemplateOptions: ["missingkey=error"]` — a typo'd variable fails the sync instead of rendering empty.
- Pin chart versions and image tags; never use a floating tag.
- Pod security: OpenShift `restricted-v2` rejects hardcoded UIDs. Never set `runAsUser`/`runAsGroup`/`fsGroup`; null them out of chart defaults so the namespace assigns them. Keep `runAsNonRoot` and `seccompProfile: RuntimeDefault`.
- Adding a product requires an element in **both** cluster ApplicationSets (or one, for the set it belongs to).
- Adding a cluster-scoped kind (CRD, webhook, ClusterRole…) requires a matching entry in `bootstrap/appproject-platform.yaml`'s `clusterResourceWhitelist`.

## Known gaps

Deliberately unfinished — do not "fix" without checking first:

- **SOPS MAC vs kustomize.** kustomize alphabetises keys; SOPS' MAC is order-sensitive, so `sops --decrypt` on rendered output fails even though the source files decrypt fine. Argo uses sops's stable `decrypt` package, which verifies the MAC, so this is expected to block the three secrets on first sync. Deferred: possible fixes are letting CNPG own the DB passwords (removes all three SOPS files), ksops in the repo-server, or splitting Secrets out of kustomize.
- **No TLS.** `apps/matrix-stack/base/values.yaml` sets `ingress.tlsEnabled: false` because no cert-manager issuer or `tlsSecret` is wired up. Federation over plain HTTP will not work.
- **Placeholder hostnames.** `matrix.example.com` and its subdomains are live values on every push to `main`.
- **No environment split.** One `values.yaml` per product serves both clusters, but they differ: `matrix-stack` emits `Ingress` only, so odcrijswijk (Gateway API) gets nothing routable, while also receiving SCC nulling it does not need.
- **`apps/valkey` declares no namespace.** The chart never templates `metadata.namespace` and kustomize's `namespace:` field does not backfill `helmCharts` output, so valkey takes the ApplicationSet destination. It works only because that destination is `cotw-valkey`, matching the FQDN hardcoded in `apps/matrix-stack/base/values.yaml`. In `odcnoord-community-pioniers` the destination is `cotw-pioniers-valkey`, so that FQDN is wrong there until overridden.
- **No backups** configured for any CNPG `Cluster`.
- **No NetworkPolicies, no ServiceMonitors, no image digest pinning**, and a single age recipient with no rotation procedure.