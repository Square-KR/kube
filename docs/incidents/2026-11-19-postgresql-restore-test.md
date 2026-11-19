# PostgreSQL 볼륨 백업 복원 시험

| 항목 | 내용 |
|---|---|
| 일시 | 2026-11-19 13:44 ~ 13:53 KST |
| 유형 | 작업 |
| 대상 | PostgreSQL 데이터 볼륨 `squarek8s-postgres-data`와 정기 백업 |
| 상태 | 완료 |

## 요약

2026-11-19 03:00 KST 정기 백업에서 새 볼륨을 만들어 DB 호스트에 추가로 붙이고, 운영 인스턴스와 분리된 임시 PostgreSQL로 띄웠다. crash recovery가 정상 완료됐고 모든 DB·역할·테이블을 읽을 수 있었으며 btree 인덱스 검사도 통과했다. 시험 볼륨과 임시 파일은 모두 지웠다.

## 영향

없음. 운영 볼륨과 운영 PostgreSQL(`5432`)은 건드리지 않았다.

## 타임라인

| 시각 (KST) | 내용 |
|---|---|
| 13:44 | 정기 백업 1건(`AVAILABLE`, 03:00 KST 생성)과 정책 할당 확인 |
| 13:50 | 백업에서 볼륨 `squarek8s-postgres-restore-test` 생성, DB 호스트에 paravirtualized로 연결 |
| 13:51 | `/mnt/pgrestore`에 마운트, 임시 PostgreSQL을 포트 `5433` Unix 소켓 전용으로 시작. crash recovery 완료 |
| 13:52 | 운영 DB와 행 수·역할 비교, `pg_dump`, `amcheck` |
| 13:53 | 임시 인스턴스 정지, 언마운트, 볼륨 분리·삭제 |

## 배경과 원인

2026-11-19 볼륨 백업 정책을 도입한 뒤 복원을 한 번도 하지 않아 백업이 실제로 쓸 수 있는지 알 수 없었다.

## 조치

저장소 밖에서 한 작업:

- OCI CLI(`--profile k8s-tf`)로 최신 정기 백업에서 같은 AD에 50 GB 볼륨을 만들고 Bastion에 연결했다. 복원 볼륨(`/dev/sdc`)은 운영 볼륨과 ext4 UUID가 같아 장치 경로로 마운트했다.
- 복원 볼륨의 `postmaster.pid`가 운영 postmaster PID를 가리켜, 복원 볼륨 쪽 파일만 지웠다.
- Ubuntu 패키지는 설정을 `/etc/postgresql`에 두므로 `/tmp/pgrestore-conf`에 임시 `postgresql.conf`(`port = 5433`, `listen_addresses = ''`, `shared_buffers = 128MB`)와 peer 인증 `pg_hba.conf`를 만들고 `pg_ctl -o "-c config_file=..."`로 시작했다.
- 검증 중 복원 볼륨의 두 DB에 `amcheck` 확장을 만들었다. 볼륨과 함께 삭제됐다.
- 시험 후 임시 인스턴스를 멈추고 `/mnt/pgrestore`, `/tmp/pgrestore-conf`, `/tmp/pgrestore-sock`을 지운 뒤 볼륨을 분리하고 삭제했다.

## 검증

- 서버 로그: `database system was not properly shut down; automatic recovery in progress` 후 `redo done`, `ready to accept connections`. 마지막 정상 시각은 2026-11-18 17:47 UTC였다.
- 역할: 복원본과 운영 모두 `honami`, `notification_backend`, `postgres`, `square_admin`, `square_datadog`.
- `square_notification`: 테이블 3개, 행 수가 운영과 같았다. `pg_dump -Fc` 12,649 bytes, btree 인덱스 48개 `bt_index_check(heapallindexed)` 통과.
- `honami`: 테이블 20개, 운영과 테이블 목록이 같았다. `pg_dump -Fc` 48,888 bytes, btree 인덱스 88개 통과. 복원본의 최신 타임스탬프는 2026-11-18 17:58:58 UTC(`school_account_syncs.synced_at`)였고, 운영과의 행 수 차이는 백업 시각 18:00 UTC 이후 생성·갱신된 행과 맞았다.
- 정리 후: 호스트 디스크는 `sda`, `sdb`만 남았고, `/var/lib/postgresql`은 `/dev/sdb`, `postgresql@16-main` `active`. 테넌시의 `AVAILABLE` 볼륨은 `squarek8s-postgres-data`뿐이다.

## 결정 사항

- 백업 내용 검증은 운영 볼륨을 교체하지 않고 별도 볼륨과 임시 인스턴스로 한다. 절차는 [PostgreSQL 런북](../runbooks/postgresql.md#백업과-복원)에 추가했다.

## 후속 작업

- PostgreSQL 운영 볼륨 교체 절차
