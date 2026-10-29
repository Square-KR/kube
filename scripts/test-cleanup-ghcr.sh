#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cleanup_script="$PWD/scripts/cleanup-ghcr.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export CLEANUP_TEST_LOG="$test_dir/deletions"
mkdir -p "$test_dir/projects/example/dev"
printf '%s\n' 'image:' '  name: ghcr.io/square-kr/example' '  version: deployed' > "$test_dir/projects/example/dev/values.yaml"
cat > "$test_dir/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == api && "$2" == --method ]]; then
  echo "$4" >> "$CLEANUP_TEST_LOG"
else
  cat <<'JSON'
[[
  {"id":1,"created_at":"2026-10-14","metadata":{"container":{"tags":["newest"]}}},
  {"id":2,"created_at":"2026-10-13","metadata":{"container":{"tags":[]}}},
  {"id":3,"created_at":"2026-10-12","metadata":{"container":{"tags":[]}}},
  {"id":4,"created_at":"2026-10-11","metadata":{"container":{"tags":["latest"]}}},
  {"id":5,"created_at":"2026-10-10","metadata":{"container":{"tags":["deployed"]}}},
  {"id":6,"created_at":"2026-10-09","metadata":{"container":{"tags":["obsolete"]}}}
]]
JSON
fi
SH
chmod +x "$test_dir/gh"
cd "$test_dir"
PATH="$test_dir:$PATH" KEEP=1 DRY_RUN=false bash "$cleanup_script"
diff -u <(printf '%s\n' '/orgs/Square-KR/packages/container/example/versions/6') "$CLEANUP_TEST_LOG"
echo 'PASS: untagged manifests, latest, deployed tags, and newest version preserved'
