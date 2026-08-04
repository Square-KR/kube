# PostgreSQL 운영 및 재구축

## 적용 구성

2026-08-04에 설치 및 재부팅 후 검증한 값이다.

| 항목 | 값 |
|---|---|
| 운영체제 | Ubuntu 24.04 LTS ARM64 |
| 인스턴스 | 2 OCPU / 8 GiB |
| PostgreSQL | 16 |
| 데이터 볼륨 | OCI Block Volume 50 GB, ext4, `/var/lib/postgresql` |
| 내부 주소 | `10.20.0.45:5432` |
| 접근 범위 | OKE 워커 서브넷 `10.20.1.0/24`만 허용 |
| 인증 | TLS + SCRAM-SHA-256 |
| 애플리케이션 DB | `square_notification` |
| 애플리케이션 역할 | `notification_backend` |

Terraform은 인스턴스와 볼륨을 생성·연결하지만 PostgreSQL 설치, 파일시스템, DB 계정, 스키마와 SSM 값은 만들지 않는다.

## 신규 설치

### 1. 인스턴스 접속과 디스크 확인

```bash
ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip)
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
```

다음 포맷 명령은 데이터를 지운다. 새로 연결된 빈 50 GB 볼륨이 `/dev/sdb`인지 `lsblk`로 확인한 경우에만 실행한다.

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

`/etc/postgresql/16/main/pg_hba.conf` 끝에 OKE 워커용 규칙 하나만 추가한다.

```conf
hostssl all all 10.20.1.0/24 scram-sha-256
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

`5`는 현재 OCI Ubuntu 이미지 기준 위치다. 실행 전 출력에서 TCP REJECT 규칙의 번호를 확인해 그 번호로 바꾼다. 같은 ACCEPT 규칙을 중복 생성하지 않는다.

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

정상 기준은 PostgreSQL `active`, `pg_isready` accepting connections, THP `[never]`, ArgoCD 전체 `Synced/Healthy`, notification-backend 파드 Ready다.

## 백업과 복원

Terraform state는 DB 백업이 아니며 현재 자동 백업과 HA는 없다. 인프라 제거 전에 수동 백업한다.

```bash
sudo -u postgres pg_dump -Fc square_notification > square_notification.dump
```

백업 파일을 인스턴스 밖의 안전한 저장소로 옮긴다. 새 DB와 역할을 만든 뒤 복원한다.

```bash
sudo -u postgres pg_restore --clean --if-exists --no-owner \
  --role=notification_backend -d square_notification square_notification.dump
```

복원 후 시퀀스, 테이블 소유자, 애플리케이션 readiness를 확인한다.
