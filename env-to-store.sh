#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
PREFIX="/dev/example-project"   # SSM 경로 prefix
KMS_KEY_ID="alias/aws/ssm"           # KMS 키

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line//$'\r'/}"

  # 공백/주석 스킵
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  # "export KEY=VALUE" 형태도 지원
  line="${line#export }"

  # KEY=VALUE 형태만 처리
  if [[ "$line" != *"="* ]]; then
    continue
  fi

  key="${line%%=*}"
  val="${line#*=}"

  # 양끝 공백 제거
  key="$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  # 따옴표로 감싼 값이면 바깥 따옴표 제거
  if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:${#val}-2}"; fi
  if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:${#val}-2}"; fi

  name="${PREFIX}/${key}"

  aws ssm put-parameter \
    --name "$name" \
    --value "$val" \
    --type "SecureString" \
    --key-id "$KMS_KEY_ID" \
    --overwrite \
    --region ap-northeast-2
    
  echo "OK: $name"
done < "$ENV_FILE"
