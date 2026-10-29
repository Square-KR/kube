#!/bin/bash
# OKE 워커 user_data. OKE 기본 초기화를 실행한 뒤 /var/log/messages 보존 정책을 설치한다.
# 실행 중인 노드에는 로그 정책만 적용한다: sudo bash -s -- --logs-only < worker-init.sh

if [[ "${1:-}" != "--logs-only" ]]; then
  oke_init_script=$(curl --fail -m 5 -H "Authorization: Bearer Oracle" -L0 http://169.254.169.254/opc/v2/instance/metadata/oke_init_script)
  if [ $? -ne 0 ]; then
    oke_init_script=$(curl --fail -m 5 -g -H "Authorization: Bearer Oracle" -L0 http://[fd00:c1::a9fe:a9fe]/opc/v2/instance/metadata/oke_init_script)
  fi
  echo $oke_init_script | base64 --decode > /var/run/oke-init.sh
  bash /var/run/oke-init.sh
fi

set -euo pipefail

# 기본 rsyslog stanza는 주간 회전·무압축 4개 보존이라 30 GiB 루트에서 DiskPressure를 일으킨다.
sed -i '\#^/var/log/messages$#d' /etc/logrotate.d/rsyslog

cat > /etc/logrotate.d/messages <<'EOF'
/var/log/messages {
    daily
    maxsize 100M
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    dateext
    dateformat -%Y%m%d%H%M%S
    postrotate
        /usr/bin/systemctl -s HUP kill rsyslog.service >/dev/null 2>&1 || true
    endscript
}
EOF

mkdir -p /etc/systemd/system/logrotate.timer.d
cat > /etc/systemd/system/logrotate.timer.d/hourly.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
AccuracySec=5m
EOF

logrotate -d /etc/logrotate.conf > /dev/null 2>&1 || {
  logrotate -d /etc/logrotate.conf
  exit 1
}

# 이전 정책의 일자 형식 아카이브를 새 형식으로 바꿔 rotate 14 개수 제한에 포함시킨다.
# 타이머 재시작이 logrotate를 즉시 실행하므로 그 전에 끝내야 같은 파일을 동시에 압축하지 않는다.
shopt -s nullglob
for archive in /var/log/messages-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] /var/log/messages-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].gz; do
  base="${archive%.gz}"
  target="${base}000000"
  if [[ "$archive" == *.gz ]]; then
    mv "$archive" "${target}.gz"
  else
    mv "$archive" "$target"
    nice -n 19 ionice -c 3 gzip -1 "$target"
  fi
done

systemctl daemon-reload
systemctl restart logrotate.timer
