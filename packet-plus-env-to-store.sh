#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/../packet-plus/apps/backend/.env}"
REGION="ap-northeast-2"

command -v aws >/dev/null || { echo "aws CLI가 필요합니다." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3가 필요합니다." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo ".env를 찾을 수 없습니다: $ENV_FILE" >&2; exit 1; }

for key in APP_ENV DATABASE_URL BETTER_AUTH_URL FRONTEND_ORIGIN NOTIFICATION_BASE_URL; do
  [[ "$(grep -c "^${key}=" "$ENV_FILE")" -eq 1 ]] || {
    echo "$ENV_FILE에 ${key}= 항목이 정확히 하나 있어야 합니다." >&2
    exit 1
  }
done

read -r -s -p "packet_plus_prod_backend 비밀번호: " prod_password
printf '\n'
[[ -n "$prod_password" ]] || { echo "prod 비밀번호가 비어 있습니다." >&2; exit 1; }

urlencode() {
  python3 -c 'import sys; from urllib.parse import quote; print(quote(sys.stdin.read(), safe=""), end="")'
}

prod_password_encoded="$(printf '%s' "$prod_password" | urlencode)"
unset prod_password

prod_database_url="postgresql://packet_plus_prod_backend:${prod_password_encoded}@10.20.0.45:5432/packet_plus_prod?sslmode=require"
unset prod_password_encoded

render_env() {
  local app_env="$1"
  local database_url="$2"
  local better_auth_url="$3"
  local frontend_origin="$4"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      APP_ENV=*) printf 'APP_ENV=%s\n' "$app_env" ;;
      DATABASE_URL=*) printf 'DATABASE_URL=%s\n' "$database_url" ;;
      BETTER_AUTH_URL=*) printf 'BETTER_AUTH_URL=%s\n' "$better_auth_url" ;;
      FRONTEND_ORIGIN=*) printf 'FRONTEND_ORIGIN=%s\n' "$frontend_origin" ;;
      NOTIFICATION_BASE_URL=*) printf 'NOTIFICATION_BASE_URL=http://notification-backend.dev.svc.cluster.local\n' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$ENV_FILE"
}

upload() {
  local prefix="$1"
  local app_env="$2"
  local database_url="$3"
  local better_auth_url="$4"
  local frontend_origin="$5"

  echo "Uploading ${prefix}"
  ENV_FILE=<(render_env "$app_env" "$database_url" "$better_auth_url" "$frontend_origin") \
    PREFIX="$prefix" \
    bash "$SCRIPT_DIR/env-to-store.sh"
}

upload \
  "/prod/packet-plus-backend" \
  "production" \
  "$prod_database_url" \
  "https://api.packet.plus" \
  "https://packet.plus"

unset prod_database_url

echo "Stored parameters: /prod/packet-plus-backend"
aws ssm get-parameters-by-path \
  --path "/prod/packet-plus-backend" \
  --recursive \
  --region "$REGION" \
  --query 'Parameters[].Name' \
  --output text | tr '\t' '\n' | sort
