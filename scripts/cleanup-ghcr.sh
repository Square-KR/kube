#!/usr/bin/env bash
set -euo pipefail

ORG="${ORG:-Square-KR}"
KEEP="${KEEP:-5}"
DRY_RUN="${DRY_RUN:-true}"
PACKAGE_TYPE="container"

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || (( KEEP < 1 )); then
  echo "KEEP must be a positive integer: ${KEEP}" >&2
  exit 1
fi

if [[ "$DRY_RUN" != "true" && "$DRY_RUN" != "false" ]]; then
  echo "DRY_RUN must be true or false: ${DRY_RUN}" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if ! command -v ruby >/dev/null 2>&1; then
  echo "ruby is required" >&2
  exit 1
fi

deployed_tags_for_package() {
  local package="$1"

  find projects -path '*/values.yaml' -type f | sort | while IFS= read -r values_file; do
    ruby -ryaml -e '
      package = ARGV.fetch(0)
      data = YAML.load_file(ARGV.fetch(1)) || {}
      image = data.fetch("image", {}) || {}
      name = image["name"].to_s
      version = image["version"].to_s
      puts version if !version.empty? && name.split("/").last == package
    ' "$package" "$values_file"
  done
}

packages_from_values() {
  find projects -path '*/values.yaml' -type f | sort | while IFS= read -r values_file; do
    ruby -ryaml -e '
      data = YAML.load_file(ARGV.fetch(0)) || {}
      image = data.fetch("image", {}) || {}
      name = image["name"].to_s
      puts name.split("/").last if name.start_with?("ghcr.io/")
    ' "$values_file"
  done | sed '/^$/d' | sort -u
}

packages_from_values | while IFS= read -r package; do
  echo "Checking ${package}"

  versions_error_file="$(mktemp)"
  if ! versions_json="$(gh api --paginate --slurp "/orgs/${ORG}/packages/${PACKAGE_TYPE}/${package}/versions?per_page=100" 2>"$versions_error_file")"; then
    cat "$versions_error_file" >&2
    rm -f "$versions_error_file"
    echo "::error::Cannot access GHCR package ${ORG}/${package}. Grant this workflow repository Admin access in Package settings > Manage Actions access." >&2
    exit 1
  fi
  rm -f "$versions_error_file"

  protected_tags_file="$(mktemp)"
  {
    echo "latest"
    deployed_tags_for_package "$package"
  } | sed '/^$/d' | sort -u >"$protected_tags_file"

  deletable_json="$(
    jq --slurpfile protected <(jq -R . "$protected_tags_file" | jq -s .) --argjson keep "$KEEP" '
      add
      | sort_by(.created_at) | reverse
      | to_entries
      | map(.value + {rank: (.key + 1)})
      | map(select(
          .rank > $keep
          and ((.metadata.container.tags // []) as $tags
            | all($protected[0][]; . as $protected_tag | ($tags | index($protected_tag) | not)))
        ))
    ' <<<"$versions_json"
  )"

  delete_count="$(jq 'length' <<<"$deletable_json")"

  if [[ "$delete_count" == "0" ]]; then
    echo "No old versions to delete for ${package}"
    rm -f "$protected_tags_file"
    continue
  fi

  jq -r '.[] | [.id, .created_at, ((.metadata.container.tags // []) | join(","))] | @tsv' <<<"$deletable_json" |
    while IFS=$'\t' read -r version_id created_at tags; do
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "Would delete ${package} version=${version_id} created_at=${created_at} tags=${tags}"
      else
        echo "Deleting ${package} version=${version_id} created_at=${created_at} tags=${tags}"
        gh api --method DELETE "/orgs/${ORG}/packages/${PACKAGE_TYPE}/${package}/versions/${version_id}"
      fi
    done

  rm -f "$protected_tags_file"
done
