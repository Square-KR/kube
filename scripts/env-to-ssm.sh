#!/usr/bin/env bash
# .env 파일의 KEY=VALUE를 AWS SSM Parameter Store SecureString으로 올린다.
# 사용법: PREFIX=/dev/notification-backend ENV_FILE=.env scripts/env-to-ssm.sh
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
PREFIX="${PREFIX:-}"
KMS_KEY_ID="${KMS_KEY_ID:-alias/aws/ssm}"
AWS_REGION="ap-northeast-2"

if [[ ! "$PREFIX" =~ ^/[a-z0-9-]+/[a-z0-9-]+$ ]]; then
  echo "PREFIX must look like /{env}/{service} or /infrastructure/{name}: '${PREFIX}'" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line//$'\r'/}"

  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  line="${line#export }"

  if [[ "$line" != *"="* ]]; then
    continue
  fi

  key="${line%%=*}"
  val="${line#*=}"

  key="$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:${#val}-2}"; fi
  if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:${#val}-2}"; fi

  name="${PREFIX}/${key}"

  aws ssm put-parameter \
    --name "$name" \
    --value "$val" \
    --type "SecureString" \
    --key-id "$KMS_KEY_ID" \
    --overwrite \
    --region "$AWS_REGION" >/dev/null

  echo "OK: $name"
done < "$ENV_FILE"
