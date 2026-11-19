# 워커 노드 DiskPressure

| 항목 | 내용 |
|---|---|
| 일시 | 2026-09-10 조사·응급 정리, 2026-10-29와 2026-11-19 재발 방지 적용 |
| 유형 | 장애 |
| 대상 | OKE 워커 `10.20.1.196`, `10.20.1.55` (2026-10-09 업그레이드 때 `10.20.1.108`, `10.20.1.58`로 교체) |
| 상태 | 완료 |

## 요약

두 워커의 루트 파일시스템이 80~85%까지 차서 DiskPressure로 Argo CD repo-server가 축출되고 여러 앱의 Sync가 실패했다. 원인은 주간 회전·무압축으로 쌓인 `/var/log/messages`였고, 그 대부분은 Datadog Agent가 일으킨 SELinux 진단 로그였다. 과거 아카이브를 압축해 약 21.84 GiB를 회수했고, 이후 로그 보존 정책(2026-10-29)과 Datadog Agent SELinux 타입 변경(2026-11-19)으로 재발 원인을 없앴다.

## 영향

- DiskPressure로 repo-server가 축출되고 양쪽 노드에 disk-pressure taint가 생겨 대체 Pod 스케줄링도 지연됐다.
- Argo CD가 `repo-server:8081 connection refused`로 매니페스트를 생성하지 못해 notification-backend-dev를 포함한 여러 앱에서 Sync가 실패했다.
- kubelet 이미지 GC 기준은 사용률 85%/80%, imagefs 축출 기준은 여유 공간 15%였다. 이미지 정리는 사용 중인 이미지와 시스템 로그를 지울 수 없어 `FreeDiskSpaceFailed`가 반복됐다.
- 2026-10-09 OKE 업그레이드 중 같은 원인으로 재발했다([OKE 업그레이드 기록](2026-10-09-oke-upgrade.md)).

## 배경과 원인

- 두 노드의 `/var/log`가 각각 약 14 GiB였다. 대부분 `/var/log/messages`와 회전된 과거 파일 4개였고, Pod 로그는 각각 약 18~19 MiB, audit 로그는 약 35~37 MiB였다.
- `/etc/logrotate.conf`는 `weekly`, `rotate 4`, `dateext`이고 `compress`는 주석 처리되어 있었다. `/etc/logrotate.d/rsyslog`가 이 기본값을 상속했고 logrotate 타이머는 하루 한 번 실행됐다.
- 8월 16일·23일·30일, 9월 6일 messages 파일 4개가 노드별 12,230,760,450 / 12,816,828,742 바이트였다. 회전은 동작했지만 주간 회전과 무압축 4개 보관이 작은 루트 파일시스템에 맞지 않았다.
- 최근 messages 20,000행 중 setroubleshoot가 첫 노드 5,905행, 둘째 노드 17,760행이었다. 주로 Datadog Agent가 `container_t` 컨텍스트로 `/host/proc`의 cgroup, fd 등에 접근할 때 생긴 SELinux 진단이다. 첫 노드에는 kubelet의 축출·재생성 로그도 많았다.
- 두 노드의 SELinux 런타임 모드는 `Permissive`였고 audit에도 `permissive=1`이 기록됐다. 접근이 막힌 것이 아니라 거부 기록과 긴 setroubleshoot 설명이 계속 쌓인 문제다.
- 부트 디스크는 50 GiB지만 루트 LVM은 29.5 GiB다. `/var/oled`에 15 GiB가 따로 할당되어 있고 VG 여유 공간은 0이다.
- 컨테이너 로그는 이미 `containerLogMaxSize: 20Mi`, `containerLogMaxFiles: 5`로 제한되어 있었다.

## 조치

### 응급 정리 (2026-09-10)

사용 중이 아닌 messages 과거 파일 4개씩(`messages-20260816`, `-20260823`, `-20260830`, `-20260906`)을 CPU·I/O 우선순위를 낮춰 `gzip -1`로 압축했다. 현재 messages 파일, audit 로그, DB/PV, 실행 중인 컨테이너와 이미지, SELinux 설정은 바꾸지 않았다.

| 노드 | 원본 아카이브 | 압축본 | 회수 공간 | 루트 사용률 |
|---|---:|---:|---:|---:|
| `10.20.1.196` | 11.39 GiB | 0.74 GiB | 10.66 GiB | 80% → 48% |
| `10.20.1.55` | 11.94 GiB | 0.76 GiB | 11.18 GiB | 85% → 48% |

### 재발 방지

| 커밋 | 내용 |
|---|---|
| `61c951e` (2026-10-29) | `terraform/worker-init.sh`: messages를 rsyslog stanza에서 분리해 `daily`, `maxsize 100M`, `rotate 14`, `compress`, `delaycompress`, `dateformat -%Y%m%d%H%M%S`로 관리하고 logrotate 타이머를 매시간 실행. node pool `user_data`로 연결 |
| `e086095` (2026-11-19) | Datadog node Agent를 `spc_t` SELinux 타입으로 실행 |

저장소 밖에서 한 작업:

- 2026-10-29: 실행 중인 두 노드(`10.20.1.58`, `10.20.1.108`)에 `--logs-only`로 정책을 적용했다. 기존 rsyslog stanza는 각 노드의 `/root/logrotate-rsyslog.bak`에 백업했다.
- 이전 형식의 `messages-YYYYMMDD` 아카이브를 `messages-YYYYMMDD000000.gz`로 바꿔 `rotate 14` 개수 제한에 포함했다.
- 첫 노드에서 타이머 재시작으로 logrotate가 즉시 실행되어, 스크립트가 압축 중이던 아카이브를 동시에 압축했다. `.gz`와 `.backup`의 압축 해제 내용이 같음을 md5로 확인하고 중복 `.backup`을 지웠다. 스크립트는 이후 아카이브 변환을 타이머 재시작보다 먼저 하도록 고쳤다.

## 검증

- 응급 정리: 첫 노드 압축본 4개가 `gzip -t`를 통과했다. 둘째 노드 검증은 기록 시점에 진행 중이었고 이후 노드가 교체되어 결과가 남아 있지 않다. 두 노드 모두 루트 48%, `Ready=True`, `DiskPressure=False`, 알림 앱 Synced/Healthy였다.
- 로그 정책: `10.20.1.58`은 72% → 50%, `10.20.1.108`은 82% → 57%가 됐다. 적용 당시 setroubleshoot 로그가 하루 약 500 MB라 `rotate 14`는 약 2~3일 보존이었다.
- SELinux 타입 변경: 거부 기록이 멈췄고 두 노드의 CPU idle이 0%에서 80~90%로 돌아왔다. 그전에는 setroubleshootd가 노드당 1 vCPU의 20~35%를 상시 사용했다.

## 결정 사항

- `rotate 14`는 14일이 아니라 아카이브 14개다. 장기 보존이 필요한 로그는 중앙 수집으로 다룬다.
- secure, audit 등 보안 로그의 보존 정책은 바꾸지 않는다.
- SELinux 전체 비활성화, audit 차단, setroubleshoot 메시지 숨김, `audit2allow` 결과의 무검토 적용은 해결책으로 쓰지 않는다.
- `/var/oled`를 지우거나 LVM을 줄여 루트를 늘리지 않는다. 디스크 증설이 필요하면 부트 볼륨, 파티션, PV, 루트 LV, XFS 확장까지 검증한다.
- 경보는 Datadog UI에서 직접 구성한다.

근거: [Logrotate](https://github.com/logrotate/logrotate/blob/main/logrotate.8.in), [Kubernetes 노드 압력 축출](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/), [이미지·컨테이너 GC](https://kubernetes.io/docs/concepts/architecture/garbage-collection/).

## 후속 작업

[backlog](../backlog.md): 노드 CPU·디스크 경보, SELinux 모드 불일치.
