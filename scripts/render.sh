#!/usr/bin/env bash
set -euo pipefail

# Render every product listed in each of a cluster's ApplicationSets to
# render/<cluster>/<set>/<product>.yaml using `kustomize build --enable-helm`.
#
# Each ApplicationSet is the source of truth for which products a cluster gets,
# so adding a product there automatically adds it here. The source directory and
# output subdirectory are taken from the ApplicationSet's own
# spec.template.spec.source.path (e.g. "apps/{{.product}}" -> "apps",
# "platform/{{.product}}" -> "platform"), so a new ApplicationSet needs no
# changes here.
#
# Renders are currently identical across clusters (values are shared per
# product); the only per-cluster difference is the ApplicationSet destination
# namespace, which is reported when it disagrees with the namespaces the
# manifests declare.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTERS_DIR="$REPO_ROOT/clusters"
OUT_ROOT="$REPO_ROOT/render"

usage() {
  cat <<'EOF'
Render every product listed in each cluster's ApplicationSets.

Usage:
  scripts/render.sh                 all clusters
  scripts/render.sh odcnoord        one cluster
  scripts/render.sh --help

Output:
  render/<cluster>/<set>/<product>.yaml
  where <set> is the first path segment of the ApplicationSet source.path
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in kustomize helm python3; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

clusters=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) clusters+=("$arg") ;;
  esac
done

if [[ ${#clusters[@]} -eq 0 ]]; then
  for d in "$CLUSTERS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    clusters+=("$(basename "$d")")
  done
fi

for cluster in "${clusters[@]}"; do
  appsets=("$CLUSTERS_DIR/$cluster"/*-applicationset.yaml)
  [[ -f "${appsets[0]:-}" ]] \
    || die "no ApplicationSet for cluster '$cluster'"
done

# PATH, DEST, then one PRODUCT<TAB>rev line per element.
parse_appset() {
  python3 - "$1" <<'PY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
spec = doc["spec"]
print("PATH\t%s" % spec["template"]["spec"]["source"]["path"])
print("DEST\t%s" % spec["template"]["spec"]["destination"]["namespace"])
for gen in spec.get("generators", []):
    for el in (gen.get("list") or {}).get("elements", []):
        print("PRODUCT\t%s\t%s" % (el["product"], el.get("rev", "")))
PY
}

# Prints "<resource-count>TAB<comma-separated declared namespaces>"
summarise() {
  python3 - "$1" <<'PY'
import sys, yaml

count = 0
namespaces = set()
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(doc, dict):
        continue
    count += 1
    ns = (doc.get("metadata") or {}).get("namespace")
    if ns:
        namespaces.add(ns)
print("%d\t%s" % (count, ",".join(sorted(namespaces))))
PY
}

failures=0
printf '%-12s %-9s %-26s %-10s %-6s %s\n' CLUSTER SET PRODUCT RESOURCES STATUS NOTES

for cluster in "${clusters[@]}"; do
  for appset in "$CLUSTERS_DIR/$cluster"/*-applicationset.yaml; do
    [[ -f "$appset" ]] || continue

    appset_data="$(parse_appset "$appset")"
    path_tmpl="$(printf '%s\n' "$appset_data" | awk -F'\t' '$1 == "PATH" { print $2 }')"
    dest_ns="$(printf '%s\n' "$appset_data" | awk -F'\t' '$1 == "DEST" { print $2 }')"
    products="$(printf '%s\n' "$appset_data" | awk -F'\t' '$1 == "PRODUCT" { print $2 }')"

    set_name="${path_tmpl%%/*}"
    out_dir="$OUT_ROOT/$cluster/$set_name"
    mkdir -p "$out_dir"

    while IFS= read -r product; do
      [[ -n "$product" ]] || continue
      status="ok"
      notes=""
      resources="-"
      src="${path_tmpl//\{\{.product\}\}/$product}"
      out_file="$out_dir/$product.yaml"

      if [[ ! -d "$REPO_ROOT/$src" ]]; then
        status="FAIL"
        notes="$src is missing"
        failures=$((failures + 1))
      elif ! err="$(kustomize build --enable-helm "$REPO_ROOT/$src" 2>&1 > "$out_file")"; then
        # Do not leave a half-written manifest behind that looks valid.
        : > "$out_file"
        status="FAIL"
        notes="$(printf '%s' "$err" | tail -n 1)"
        failures=$((failures + 1))
      else
        summary="$(summarise "$out_file")"
        resources="${summary%%$'\t'*}"
        manifest_ns="${summary#*$'\t'}"
        resolved_ns="${dest_ns//\{\{.product\}\}/$product}"
        if [[ -z "$manifest_ns" ]]; then
          notes="no namespace declared; Argo falls back to destination '$resolved_ns'"
        else
          outside=""
          IFS=',' read -ra ns_list <<< "$manifest_ns"
          for n in "${ns_list[@]}"; do
            [[ "$n" == cotw-* ]] || outside="$n"
          done
          if [[ -n "$outside" ]]; then
            notes="namespace '$outside' is outside AppProject destinations cotw-*"
          elif [[ "$manifest_ns" != "$resolved_ns" ]]; then
            notes="declares ns '$manifest_ns'; destination '$resolved_ns'"
          fi
        fi
      fi

      printf '%-12s %-9s %-26s %-10s %-6s %s\n' \
        "$cluster" "$set_name" "$product" "$resources" "$status" "$notes"
    done <<< "$products"

    # Anything left over from an earlier run is no longer in the ApplicationSet.
    while IFS= read -r stale; do
      [[ -n "$stale" ]] || continue
      base="$(basename "$stale" .yaml)"
      if ! printf '%s\n' "$products" | grep -qx "$base"; then
        rel="${stale#"$REPO_ROOT"/}"
        printf '%-12s %-9s %-26s %-10s %-6s %s\n' \
          "$cluster" "$set_name" "$base" "-" "STALE" "not in $(basename "$appset") -- delete $rel"
      fi
    done < <(find "$out_dir" -maxdepth 1 -name '*.yaml' | sort)
  done

  # Renders from before output was split per ApplicationSet.
  while IFS= read -r stale; do
    [[ -n "$stale" ]] || continue
    rel="${stale#"$REPO_ROOT"/}"
    printf '%-12s %-9s %-26s %-10s %-6s %s\n' \
      "$cluster" "-" "$(basename "$stale" .yaml)" "-" "STALE" "legacy path -- delete $rel"
  done < <(find "$OUT_ROOT/$cluster" -maxdepth 1 -name '*.yaml' | sort)
done

echo
if [[ "$failures" -gt 0 ]]; then
  printf '%d render(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all renders OK -> %s\n' "$OUT_ROOT"
