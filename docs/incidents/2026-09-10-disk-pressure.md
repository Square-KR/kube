# 워커 노드 DiskPressure 조사 및 재발 방지 계획

조사일: 2026-09-10. 대상: OKE 워커 `10.20.1.196`, `10.20.1.55`.

## 현재 상태 (2026-10-29)

- 응급 정리만 수행했고 아래 재발 방지 계획 1~3은 아직 적용하지 않았다. Terraform 워커에 `node_metadata.user_data`가 없다.
- 2026-10-09 OKE 업그레이드 중 같은 원인으로 재발했다. 자세한 내용은 [OKE 업그레이드 기록](2026-10-09-oke-upgrade.md)에 있다.
- 위 두 노드는 업그레이드 때 `10.20.1.108`, `10.20.1.58`로 교체되었다. 교체 19일 후 루트 사용률이 각각 82%, 71%로 다시 올라와 있어 계획 1의 적용이 시급하다.

## 확인한 원인

- 두 노드의 `/var/log`가 각각 약 14 GiB를 사용했다. 대부분 `/var/log/messages`와 회전된 과거 파일 4개였다. Pod 로그는 각각 약 18~19 MiB, audit 로그는 약 35~37 MiB였다.
- `/etc/logrotate.conf`는 `weekly`, `rotate 4`, `dateext`이며 `compress`는 주석 처리되어 있었다. `/etc/logrotate.d/rsyslog`는 이 기본값을 상속했다. logrotate 타이머는 하루 한 번 실행된다.
- 8월 16일·23일·30일, 9월 6일의 messages 파일 4개가 노드별 12,230,760,450 / 12,816,828,742 바이트를 차지했다. 회전은 동작하지만, 주간 회전과 무압축 4개 보관이 작은 루트 파일시스템에 맞지 않았다.
- 최근 messages 20,000행에서 setroubleshoot가 첫 노드 5,905행, 둘째 노드 17,760행을 차지했다. 주로 Datadog Agent의 `/host/proc` 내 cgroup, fd 등 접근에 대한 SELinux 진단이다. 첫 노드에는 kubelet의 축출·재생성 관련 로그도 많았다.
- 실제 SELinux 모드는 두 노드 모두 `Permissive`; audit 기록에도 `permissive=1`이 확인됐다. 따라서 이 시점에 실제 접근을 막는다는 뜻은 아니다. 권한 불일치가 audit 이벤트와 긴 setroubleshoot 설명으로 계속 기록되는 문제다. 파일 설정의 `SELINUX=enforcing`과 런타임 모드 차이도 별도로 관리해야 한다.
- 부트 디스크는 50 GiB이나 루트 LVM은 29.5 GiB다. `/var/oled`에 15 GiB가 별도 할당되어 있으며 VG 여유 공간은 0이다. 부트 디스크 전체가 Kubernetes 임시 저장소로 사용되는 구조가 아니다.

## 서비스 영향

- 노드의 DiskPressure로 repo-server가 축출되고, 양쪽 노드에 disk-pressure taint가 생겨 대체 Pod 스케줄링도 지연됐다.
- Argo CD는 `repo-server:8081 connection refused`로 매니페스트를 생성하지 못했고, notification-backend-dev를 포함한 여러 앱에서 Sync가 실패했다.
- kubelet의 이미지 GC 기준은 사용률 85%/80%, imagefs 축출 기준은 여유 공간 15%였다. 이미지 정리는 사용 중인 이미지와 시스템 로그를 지울 수 없어 반복적인 `FreeDiskSpaceFailed`가 발생했다.
- 컨테이너 로그 자체는 `containerLogMaxSize: 20Mi`, `containerLogMaxFiles: 5`로 이미 제한되어 있었다. 이 값을 먼저 바꿔도 messages 누적 원인은 해결되지 않는다.

## 이번 정리 범위

- 두 노드에서 사용 중이 아닌 일반 파일임을 확인한 messages 과거 파일 4개씩을 `gzip -1`로 압축한다. CPU와 I/O 우선순위를 낮춰 실행하고 완료 후 `gzip -t`로 무결성을 확인한다.
- 대상은 `/var/log/messages-20260816`, `/var/log/messages-20260823`, `/var/log/messages-20260830`, `/var/log/messages-20260906`뿐이다. 내용은 같은 경로의 `.gz` 파일로 보존하며 `zless`/`zcat`으로 조회할 수 있다.
- 현재 messages 파일, audit 로그, DB/PV, 실행 중인 컨테이너 및 이미지, SELinux 설정은 변경하지 않는다.
- 수동 압축은 응급 공간 확보다. 현재 무압축 logrotate 정책에서는 이 `.gz` 파일들이 자동 보존 개수에 포함된다고 가정하지 않는다. 아래 정책 전환 시 기존 아카이브의 정리 여부도 함께 검증한다.

### 정리 결과

| 노드 | 원본 아카이브 | 압축본 | 회수 공간 | 루트 사용률 |
|---|---:|---:|---:|---:|
| `10.20.1.196` | 11.39 GiB | 0.74 GiB | 10.66 GiB | 80% → 48% |
| `10.20.1.55` | 11.94 GiB | 0.76 GiB | 11.18 GiB | 85% → 48% |

총 약 21.84 GiB를 회수했다. 첫 노드의 압축본 4개는 `gzip -t` 검증을 통과했다. 두 번째 노드의 검증은 기록 시점에 실행 중이었고, 이후 노드가 교체되어 결과는 남아 있지 않다. 두 노드 모두 루트 사용률 48%, Ready=True, DiskPressure=False이며 알림 앱은 Synced/Healthy/Succeeded로 확인했다. 정리 중 새 애플리케이션 이미지도 배포되었으므로 아카이브에서 회수한 용량과 루트 사용량의 감소 폭은 정확히 같지 않다.

## 재발 방지 구현 계획

### 1. messages 보존량 제한 — 우선 적용

- `/var/log/messages`를 기존 rsyslog stanza에서 분리하여 중복 매칭 없이 별도 정책으로 관리한다. secure/audit 등 보안 로그의 보존 정책은 이번 변경에 포함하지 않는다.
- messages에 `daily`, `maxsize 100M`, `rotate 14`, `compress`, `delaycompress`, `missingok`, `notifempty`를 적용한다. 기존 파일 소유권·권한과 rsyslog HUP postrotate를 유지한다.
- logrotate 타이머를 매시간 실행하고 `AccuracySec=5m`로 설정한다. `maxsize`는 실행 시 검사하는 기준이며 정확한 실시간 크기 상한은 아니다.
- 하루 여러 번 회전할 수 있도록 `dateformat -%Y%m%d%H%M%S`를 사용한다. 기본 일자만 붙이면 같은 날 두 번째 회전이 충돌할 수 있다.
- `rotate 14`는 14일이 아니라 **아카이브 14개**다. 크기 기준 회전이 잦으면 보존 기간은 짧아진다. 이번 압축본 8개의 보존 종료는 정책 전환일로부터 14일 후로 정하고, 그때 정확한 파일 목록을 확인하여 제거한다. 장기 보존이 필요한 로그는 별도 중앙 수집·보존 정책으로 다룬다.
- `logrotate -d`로 중복 stanza와 날짜 충돌을 확인하고 한 노드에서 먼저 적용한다. rsyslog가 새 파일에 쓰는지 확인한 뒤 다른 노드에 적용한다.
- 이 정책과 타이머 drop-in을 저장소의 노드 부트스트랩 스크립트로 관리하고 Terraform 워커 `node_metadata.user_data`에 연결한다. OKE 기본 초기화를 보존하며, 기존 노드는 순차 적용하고 신규 노드에서도 같은 정책이 설치되도록 한다. apply 전 node pool 교체 여부를 plan으로 확인한다.

근거: [Logrotate 설정 문서](https://github.com/logrotate/logrotate/blob/main/logrotate.8.in).

### 2. Datadog SELinux 진단 폭증 해소

- 변경 대상은 `observability/datadog/datadog-agent.yaml`과 필요한 노드 정책이다. 현재 nodeAgent는 root로 실행하지만 전용 SELinux 컨텍스트 설정이 없고, audit의 source context는 `container_t`다.
- 실제 AVC의 source/target context, 파일 클래스, 필요한 접근을 정리한 뒤 Datadog Agent 전용 컨텍스트·정책을 검증한다. 일반 `container_t` 전체에 접근을 허용하는 정책이나 audit2allow 결과의 무검토 적용은 피한다.
- 전체 SELinux 비활성화, audit 로그 차단, setroubleshoot 메시지 숨김을 원인 해결로 취급하지 않는다. 현재 Permissive에서도 경고가 계속 발생하는 것이 확인됐다.
- 먼저 한 노드의 Agent로 컨테이너 로그 수집, APM, OTEL, PostgreSQL DBM을 유지하는지 확인한다. 새로운 Agent 관련 AVC가 발생하지 않는 것을 확인한 뒤 전체 적용한다.
- SELinux Enforcing 전환은 이번 디스크 정리와 분리한다. 노드 기본 정책과 모든 hostPath 사용 워크로드의 호환성을 별도 검증해야 한다.

### 3. 경보와 용량 기준

- Datadog에서 루트 파일시스템 사용률 70%가 15분 지속되면 경고, 80%가 5분 지속되면 심각 경보를 보낸다. `/var/oled` 등 별도 파일시스템과 구분하여 루트를 감시한다.
- `DiskPressure=True`가 1분 지속되거나 Argo CD repo-server Ready replica가 0이면 즉시 경보한다. 알림 채널은 기존 인프라 운영 채널을 사용한다.
- messages의 하루 증가량과 logrotate 실행 실패를 함께 수집한다. 이 지표를 수집하는 설정을 먼저 추가하고, 존재하지 않는 메트릭으로 모니터를 만들지 않는다.
- 로그 정책 적용 후 7일간 관찰한다. 정상 상태에서도 루트 사용률이 60%를 넘거나 배포 중 70%를 넘으면 노드 디스크 증설을 계획한다.
- 당장은 압축·보존 설정으로 확보되는 공간을 먼저 검증한다. `/var/oled`를 삭제하거나 LVM을 축소해 루트를 늘리는 작업은 포함하지 않는다. 증설 시 부트 볼륨뿐 아니라 파티션·PV·루트 LV·XFS 확장까지 검증해야 한다.

근거: [Kubernetes 노드 압력 축출](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/), [이미지·컨테이너 GC](https://kubernetes.io/docs/concepts/architecture/garbage-collection/).

## 완료 기준과 롤백

- 응급 정리: 압축본 8개 무결성 통과, 두 노드의 루트 여유 공간 10 GiB 이상, Ready=True 및 DiskPressure=False, repo-server Ready 확인.
- 정책 적용: 최소 48시간 새 DiskPressure 축출 없음, 시간당 rotation 실행 성공, 새 messages에 정상 기록, 아카이브 압축·보존 개수 준수, Datadog 수집 유지.
- Datadog 변경 실패 시 해당 Git 변경을 되돌려 Argo CD로 복구한다. 로그 정책 변경 실패 시 백업한 기존 stanza와 timer 설정을 복구한다. 압축본은 보존하되 디스크 여유 확인 없이 전체 압축 해제하지 않는다.
- 이번 요청에서는 응급 정리를 실행하고 영구 설정 변경은 이 문서의 계획으로 남긴다.
