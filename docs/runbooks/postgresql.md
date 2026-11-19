# PostgreSQL 운영 및 재구축

마지막 검증: 2026-08-04 신규 설치와 재부팅, 2026-11-19 Datadog 호스트 Agent, 볼륨 백업 정책, 별도 볼륨으로 백업 내용 검증. 운영 볼륨 교체 복원은 미검증.

## 목적과 범위

Bastion 인스턴스(`10.20.0.45`)에 PostgreSQL을 설치하고 역할, 서비스 DB, Tailscale, Datadog 호스트 Agent를 구성한다. Terraform은 인스턴스와 볼륨, 볼륨 백업 정책만 만들고 PostgreSQL 설치, 파일시스템, DB 계정, 스키마, Tailscale, Datadog 호스트 Agent와 SSM 값은 만들지 않는다. Bastion 부트 이미지는 `ignore_changes`로 고정되어 있어 최신 Ubuntu 이미지가 나와도 부트 볼륨이 교체되지 않는다. 인스턴스를 의도적으로 재생성하면 이 문서의 절차를 처음부터 다시 수행한다.

## 적용 구성

2026-11-19에 호스트에서 확인한 값이다.

| 항목 | 값 |
|---|---|
| 운영체제 | Ubuntu 24.04 LTS ARM64 |
| 인스턴스 | 2 OCPU / 8 GiB |
| PostgreSQL | 16 (Ubuntu 패키지) |
| 데이터 볼륨 | OCI Block Volume 50 GB, ext4, `/var/lib/postgresql` |
| 내부 주소 | `10.20.0.45:5432` |
| 접근 범위 | OKE 워커 서브넷 `10.20.1.0/24`, Tailscale `100.64.0.0/10` |
| 인증 | TLS + SCRAM-SHA-256 |
| 애플리케이션 DB | `square_notification`, `honami` |
| 애플리케이션 역할 | `notification_backend`, `honami` (각 DB 소유자) |
| 모니터링 역할 | `square_datadog` (`pg_monitor`, superuser 아님) |
| 백업 | Block Volume 백업 정책 `squarek8s-postgres-backup` (매일 03:00 KST 증분 7일, 일요일 백업 4주 보존) |
| 원격 관리자 역할 | `square_admin` (superuser, 비밀번호는 로컬 macOS 키체인 `squarek8s-postgresql`) |

## 사전 조건

- `terraform apply`로 Bastion 인스턴스와 빈 데이터 볼륨이 연결된 상태
- `~/.ssh/squarek8s` SSH 키, 저장소 루트의 `terraform` 출력 조회 권한
- 9번 절차용: 클러스터 `kubectl` 접근, AWS SSM 조회 권한

## 절차

### 1. 인스턴스 접속과 디스크 확인

```bash
ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip)
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
```

**위험:** 다음 포맷 명령은 볼륨의 데이터를 지운다. 새로 연결된 빈 50 GB 볼륨이 `/dev/sdb`인지 `lsblk`로 확인한 경우에만 실행한다.

```bash
sudo mkfs.ext4 -L pgdata -m 0 /dev/sdb
sudo mkdir -p /var/lib/postgresql
PGDATA_UUID=$(sudo blkid -s UUID -o value /dev/sdb)
echo "UUID=$PGDATA_UUID /var/lib/postgresql ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
sudo mount -a
findmnt /var/lib/postgresql
```

### 2. PostgreSQL 설치와 체크섬

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y postgresql postgresql-contrib
sudo systemctl stop postgresql
sudo -u postgres /usr/lib/postgresql/16/bin/pg_checksums \
  --enable -D /var/lib/postgresql/16/main
sudo systemctl start postgresql
```

배포판 패키지의 메이저 버전이 16이 아니면 이후 경로의 `16`도 함께 변경한다.

### 3. PostgreSQL 튜닝

`/etc/postgresql/16/main/conf.d/99-squarek8s.conf`를 다음과 같이 만든다.

```conf
# squarek8s: 2 OCPU / 8 GiB / dedicated OCI block volume
listen_addresses = '*'
port = 5432
max_connections = 100
password_encryption = 'scram-sha-256'
ssl = on

shared_buffers = '2GB'
effective_cache_size = '6GB'
work_mem = '8MB'
maintenance_work_mem = '512MB'
autovacuum_work_mem = '256MB'
temp_buffers = '16MB'
huge_pages = try
effective_io_concurrency = 200
maintenance_io_concurrency = 200
random_page_cost = 1.1
seq_page_cost = 1.0
default_statistics_target = 200

wal_compression = on
wal_buffers = -1
min_wal_size = '1GB'
max_wal_size = '4GB'
checkpoint_timeout = '15min'
checkpoint_completion_target = 0.9

autovacuum = on
autovacuum_max_workers = 3
autovacuum_naptime = '30s'
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
autovacuum_vacuum_cost_limit = 2000
autovacuum_vacuum_cost_delay = '2ms'

shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 5000
pg_stat_statements.track = 'all'
track_io_timing = on
track_activity_query_size = 4096
log_min_duration_statement = 1000
log_checkpoints = on
log_lock_waits = on
log_autovacuum_min_duration = 1000
deadlock_timeout = '1s'
idle_in_transaction_session_timeout = '5min'

jit = off
max_worker_processes = 4
max_parallel_workers = 2
max_parallel_workers_per_gather = 1
timezone = 'UTC'
log_timezone = 'UTC'
```

`/etc/postgresql/16/main/pg_hba.conf` 끝에 OKE 워커와 Tailscale 규칙을 추가한다.

```conf
hostssl all all 10.20.1.0/24 scram-sha-256
hostssl all all 100.64.0.0/10 scram-sha-256
```

```bash
sudo systemctl restart postgresql
sudo -u postgres psql -d postgres -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
```

### 4. 운영체제 튜닝

`/etc/sysctl.d/99-postgresql.conf`:

```conf
vm.swappiness = 1
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 268435456
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
vm.zone_reclaim_mode = 0
```

```bash
sudo sysctl --system
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo systemctl enable --now fstrim.timer
```

`/etc/systemd/system/disable-thp.service`:

```ini
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=postgresql.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp.service
sudo reboot
```

### 5. 네트워크 제한

OCI Security List는 Terraform이 `10.20.1.0/24 -> TCP 5432`만 허용한다. Ubuntu iptables에도 같은 ACCEPT 규칙을 기본 REJECT 규칙보다 앞에 추가하고 영구 저장한다.

```bash
sudo iptables -L INPUT --line-numbers -n
sudo iptables -I INPUT 5 -p tcp -s 10.20.1.0/24 --dport 5432 \
  -m conntrack --ctstate NEW -j ACCEPT
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

`5`는 현재 OCI Ubuntu 이미지 기준 위치다. 실행 전 출력에서 TCP REJECT 규칙의 번호를 확인해 그 번호로 바꾼다. 같은 ACCEPT 규칙을 중복 생성하지 않는다. 공인 IP의 5432는 열지 않는다. Tailscale 트래픽은 Tailscale이 추가하는 `ts-input` 체인에서 허용된다.

### 6. 관리자 역할

비밀번호는 명령행이나 저장소에 남기지 않도록 `\password`로 입력한다.

```bash
sudo -u postgres psql
```

```sql
CREATE ROLE square_admin LOGIN SUPERUSER;
\password square_admin
```

`square_admin` 비밀번호는 노트북의 macOS 키체인에만 저장한다.

```bash
security add-generic-password -a square_admin -s squarek8s-postgresql -w
```

서비스 DB와 역할은 [서비스 DB 추가](#서비스-db-추가) 절차로 만든다. 7번과 9번은 서비스 DB가 하나 이상 있어야 진행할 수 있다.

### 7. Datadog DBM 역할

모니터링 역할은 한 번만 만든다. `datadog` 스키마, 권한, 실행 계획 수집 함수는 모니터링할 DB마다(현재 `square_notification`, `honami`, `postgres`) 접속해 만든다. `CREATE ROLE`과 `\password`는 첫 DB에서만 실행하고, `pg_stat_statements` 확장은 `postgres` DB에는 만들지 않아도 된다.

```bash
sudo -u postgres psql -d square_notification
```

```sql
CREATE ROLE square_datadog LOGIN INHERIT;
\password square_datadog
GRANT pg_monitor TO square_datadog;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE SCHEMA datadog;
GRANT USAGE ON SCHEMA datadog TO square_datadog;
GRANT USAGE ON SCHEMA public TO square_datadog;

CREATE OR REPLACE FUNCTION datadog.explain_statement(l_query text, OUT explain json)
 RETURNS SETOF json
 LANGUAGE plpgsql
 STRICT SECURITY DEFINER
AS $function$
DECLARE
  curs refcursor;
  plan json;
BEGIN
  SET TRANSACTION READ ONLY;
  OPEN curs FOR EXECUTE pg_catalog.concat('EXPLAIN (FORMAT JSON) ', l_query);
  FETCH curs INTO plan;
  CLOSE curs;
  RETURN QUERY SELECT plan;
END;
$function$;
```

같은 비밀번호를 AWS SSM `/infrastructure/datadog/postgresql-password`에 저장한다. 9번 절차에서 호스트 Agent 설정에 이 값을 쓴다.

### 8. Tailscale subnet router

노트북에서 VCN 내부 주소로 접근하기 위해 이 인스턴스를 subnet router로 사용한다.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
  | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale up --hostname=squarek8s-db-router --advertise-routes=10.20.0.0/16
```

Tailscale 관리 콘솔에서 장치의 `10.20.0.0/16` route를 승인한다. 현재 장치의 MagicDNS 이름은 `db-router-01`이다.

### 9. Datadog 호스트 Agent

이 인스턴스의 Agent가 호스트 지표(CPU, 메모리, swap, `/var/lib/postgresql` 디스크)와 PostgreSQL 지표·DBM을 모두 수집한다. Datadog는 자체 호스팅 DB를 DB 호스트의 Agent로 모니터링하도록 안내한다. 호스트 이름은 `squarek8s-postgresql`이다.

API key는 화면에 출력하지 않고 클러스터 Secret에서 SSH 표준입력으로 넘긴다. 노트북의 저장소 루트에서 실행한다.

```bash
kubectl -n datadog get secret datadog-secret -o jsonpath='{.data.api-key}' | base64 -d \
  | ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip) '
      IFS= read -r DD_API_KEY || true
      export DD_API_KEY DD_SITE=us5.datadoghq.com DD_HOSTNAME=squarek8s-postgresql DD_HOST_TAGS="env:dev,service:postgresql"
      curl -fsSL https://install.datadoghq.com/scripts/install_script_agent7.sh -o /tmp/dd-install.sh
      sudo -E bash /tmp/dd-install.sh && rm -f /tmp/dd-install.sh'
```

이 호스트에는 트레이스를 보내는 애플리케이션이 없으므로 `/etc/datadog-agent/datadog.yaml` 끝에 APM 비활성화를 추가하고 재시작한다.

```yaml
apm_config:
  enabled: false
```

```bash
sudo systemctl restart datadog-agent
sudo datadog-agent status | grep -E 'hostname:|API Key|\[(OK|ERROR)\]'
```

postgres 체크를 설정한다. 비밀번호는 화면에 출력하지 않고 SSM에서 SSH 표준입력으로 넘긴다. 비밀번호에 `"`나 `\`가 있으면 YAML 이스케이프가 필요하다.

```bash
aws ssm get-parameter --name /infrastructure/datadog/postgresql-password --with-decryption \
  --region ap-northeast-2 --query Parameter.Value --output text \
  | ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip) '
      IFS= read -r PGPW || true
      tmp=$(mktemp)
      cat > "$tmp" <<EOF
init_config:
instances:
  - host: 127.0.0.1
    port: 5432
    username: square_datadog
    password: "$PGPW"
    dbname: square_notification
    database_autodiscovery:
      enabled: true
      include:
        - square_notification$
        - honami$
    ssl: require
    dbm: true
    relations:
      - relation_regex: .*
    collect_bloat_metrics: true
    collect_wal_metrics: true
    data_directory: /var/lib/postgresql/16/main
    collect_checksum_metrics: true
EOF
      sudo install -o dd-agent -g dd-agent -m 600 "$tmp" /etc/datadog-agent/conf.d/postgres.d/conf.yaml
      rm -f "$tmp"
      sudo systemctl restart datadog-agent'
```

`include`는 모니터링할 서비스 DB 목록과 같아야 한다. `dbname`에는 `pg_stat_statements` 확장이 있는 DB를 둔다.

## 서비스 DB 추가

서비스마다 전용 역할과 그 역할이 소유한 DB를 만든다. 현재 서비스 DB는 `square_notification`(역할 `notification_backend`)과 `honami`(역할 `honami`)다. `<db>`, `<role>`을 바꿔 실행한다.

```bash
sudo -u postgres psql
```

```sql
CREATE ROLE <role> LOGIN;
\password <role>
CREATE DATABASE <db> OWNER <role>;
```

1. 접속 정보를 서비스 SSM 경로 `/{env}/{service}/` 아래 SecureString으로 저장한다. 키 이름은 서비스가 읽는 환경변수 이름을 따른다. 여러 값을 한 번에 올릴 때는 README의 서비스 시크릿 등록 절차를 쓴다.
2. 7번 절차의 SQL을 `<db>`에 접속해 실행한다. `CREATE ROLE`과 `\password`, `GRANT pg_monitor`는 건너뛴다.
3. 호스트의 `/etc/datadog-agent/conf.d/postgres.d/conf.yaml`에서 `database_autodiscovery.include`에 `<db>$`를 추가하고 `sudo systemctl restart datadog-agent`를 실행한다. 9번 절차의 설정 예시도 같이 고친다.
4. 이 문서의 "적용 구성" 표에 DB와 역할을 추가한다.

## 검증

호스트에서 확인한다.

```bash
systemctl is-active postgresql
pg_isready -h 127.0.0.1 -p 5432
findmnt /var/lib/postgresql
cat /sys/kernel/mm/transparent_hugepage/enabled
free -h
sudo -u postgres psql -Atqc "SHOW shared_buffers; SHOW effective_cache_size; SHOW password_encryption;"
```

클러스터에서 확인한다.

```bash
kubectl get applications -n argocd
kubectl get rollout,pods -n dev
kubectl logs -n dev -l app=notification-backend --tail=100
```

노트북에서 Tailscale 경로를 확인한다.

```bash
nc -vz 10.20.0.45 5432
PGPASSWORD=$(security find-generic-password -a square_admin -s squarek8s-postgresql -w) \
  psql "host=10.20.0.45 dbname=square_notification user=square_admin sslmode=require" -c 'SELECT 1'
```

정상 기준은 PostgreSQL `active`, `pg_isready` accepting connections, THP `[never]`, Tailscale 경유 접속 성공, ArgoCD 전체 `Synced/Healthy`, notification-backend 파드 Ready, 호스트의 `sudo datadog-agent status`에서 postgres 체크 `[OK]`다.

## 롤백

### 백업과 복원

Terraform의 `oci_core_volume_backup_policy.postgres`가 데이터 볼륨을 매일 03:00 KST에 증분 백업해 7일, 일요일 백업을 4주 보존한다. 볼륨 스냅샷이라 복원하면 PostgreSQL이 WAL로 crash recovery를 거쳐 올라온다. 논리 백업, 시점 복구(PITR), HA는 없다.

볼륨 백업에서 복원할 때는 OCI 콘솔이나 CLI로 백업에서 새 볼륨을 만들고, PostgreSQL을 멈춘 뒤 기존 볼륨 대신 `/var/lib/postgresql`에 마운트한다. Terraform state의 `oci_core_volume.postgres`와 어긋나므로 복원 후 state를 새 볼륨에 맞춘다. 운영 볼륨 교체 절차는 미검증이다.

#### 백업 내용 검증

운영 볼륨을 건드리지 않고 백업을 별도 볼륨으로 복원해 임시 인스턴스로 확인한다. 2026-11-19에 수행했다. OCI CLI는 Terraform과 같은 `--profile k8s-tf`로 실행한다. 기본 프로필은 `NotAuthorizedOrNotFound`를 반환한다.

```bash
cd terraform
OCI=(--profile k8s-tf --region ap-seoul-1)
COMP=$(terraform state show oci_core_volume.postgres | awk '$1 == "compartment_id" {gsub(/"/, "", $3); print $3}')
VOL=$(terraform state show oci_core_volume.postgres | awk '$1 == "id" {gsub(/"/, "", $3); print $3}')
INST=$(terraform state show oci_core_instance.bastion | awk '$1 == "id" {gsub(/"/, "", $3); print $3}')
AD=$(terraform state show oci_core_volume.postgres | awk '$1 == "availability_domain" {gsub(/"/, "", $3); print $3}')

oci bv backup list "${OCI[@]}" --compartment-id "$COMP" --volume-id "$VOL" --output table \
  --query 'data[].{id:id,state:"lifecycle-state",created:"time-created",expires:"expiration-time"}'
BACKUP=<복원할 백업 OCID>

TEST_VOL=$(oci bv volume create "${OCI[@]}" --compartment-id "$COMP" --availability-domain "$AD" \
  --volume-backup-id "$BACKUP" --display-name squarek8s-postgres-restore-test \
  --wait-for-state AVAILABLE --query data.id --raw-output)
ATTACH=$(oci compute volume-attachment attach "${OCI[@]}" --instance-id "$INST" --volume-id "$TEST_VOL" \
  --type paravirtualized --wait-for-state ATTACHED --query data.id --raw-output)
```

DB 호스트에서 새 디스크를 확인하고 마운트한다. 복원 볼륨은 운영 볼륨과 ext4 UUID가 같으므로 UUID가 아니라 장치 경로로 마운트하고 `/etc/fstab`에 넣지 않는다. 장치 이름은 `lsblk`로 확인한다.

```bash
lsblk -o NAME,SIZE,MOUNTPOINT,UUID
sudo mkdir -p /mnt/pgrestore
sudo mount -o noatime /dev/sdc /mnt/pgrestore
```

스냅샷의 `postmaster.pid`는 운영 postmaster PID를 가리켜 임시 인스턴스가 시작을 거부한다. 복원 볼륨 쪽 파일만 지운다. Ubuntu 패키지는 설정을 `/etc/postgresql`에 두므로 임시 설정 파일을 따로 만들어 Unix 소켓 전용 포트 `5433`으로 띄운다.

```bash
D=/mnt/pgrestore/16/main
sudo rm "$D/postmaster.pid"
sudo install -d -o postgres -g postgres -m 700 /tmp/pgrestore-conf /tmp/pgrestore-sock
sudo -u postgres tee /tmp/pgrestore-conf/postgresql.conf >/dev/null <<'EOF'
port = 5433
listen_addresses = ''
unix_socket_directories = '/tmp/pgrestore-sock'
hba_file = '/tmp/pgrestore-conf/pg_hba.conf'
ident_file = '/tmp/pgrestore-conf/pg_ident.conf'
shared_buffers = 128MB
max_connections = 10
EOF
echo 'local all postgres peer' | sudo -u postgres tee /tmp/pgrestore-conf/pg_hba.conf >/dev/null
sudo -u postgres touch /tmp/pgrestore-conf/pg_ident.conf
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D "$D" \
  -o '-c config_file=/tmp/pgrestore-conf/postgresql.conf' -l /tmp/pgrestore-conf/server.log -w start
```

`server.log`에서 `automatic recovery in progress` 뒤 `ready to accept connections`를 확인한다. `invalid record length ... got 0`은 WAL 끝에 도달했다는 뜻이다. 이후 `psql -h /tmp/pgrestore-sock -p 5433`으로 DB별 테이블 목록과 행 수를 운영과 비교하고, `pg_dump -Fc`로 전체를 읽고, `amcheck`의 `bt_index_check(oid, true)`로 btree 인덱스를 검사한다. 운영보다 적은 행은 백업 시각 이후의 변경과 맞는지 타임스탬프로 확인한다.

정리한다.

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /mnt/pgrestore/16/main -m fast -w stop
sudo umount /mnt/pgrestore && sudo rmdir /mnt/pgrestore
sudo rm -rf /tmp/pgrestore-conf /tmp/pgrestore-sock
```

```bash
oci compute volume-attachment detach "${OCI[@]}" --volume-attachment-id "$ATTACH" --force --wait-for-state DETACHED
oci bv volume delete "${OCI[@]}" --volume-id "$TEST_VOL" --force --wait-for-state TERMINATED
```

#### 논리 백업

DB 하나만 되돌리거나 인프라를 제거하기 전에는 `pg_dump`로 수동 백업한다.

```bash
sudo -u postgres pg_dump -Fc square_notification > square_notification.dump
```

백업 파일을 인스턴스 밖의 안전한 저장소로 옮긴다. 위의 역할과 데이터베이스 절차로 새 DB와 역할을 만든 뒤 복원한다.

```bash
sudo -u postgres pg_restore --clean --if-exists --no-owner \
  --role=notification_backend -d square_notification square_notification.dump
```

복원 후 시퀀스, 테이블 소유자, 애플리케이션 readiness를 확인한다.

## 관련 문서

- [README](../../README.md): 새 클러스터 구축 순서와 서비스 시크릿 등록
- [2026-11-19 기록](../incidents/2026-11-19-gitops-drift-and-node-cpu.md): Datadog 호스트 Agent 이전과 볼륨 백업 정책 도입
- [2026-11-19 복원 시험 기록](../incidents/2026-11-19-postgresql-restore-test.md): 정기 백업을 별도 볼륨으로 복원해 검증
