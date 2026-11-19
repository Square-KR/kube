#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for cmd in helm kubeconform; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is required" >&2; exit 1; }
done

crd_schemas='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
kubeconform_args=(-strict -summary -schema-location default -schema-location "$crd_schemas")

helm lint charts/app

for values_file in projects/*/*/values.yaml; do
  service="$(cut -d/ -f2 <<<"$values_file")"
  echo "Rendering ${values_file}"
  helm template "$service" charts/app -f "$values_file" | kubeconform "${kubeconform_args[@]}" -
done

find root.yaml system networking observability projects -name '*.yaml' ! -name values.yaml -print0 |
  xargs -0 kubeconform "${kubeconform_args[@]}"
