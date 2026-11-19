# 시크릿 자동 재시작 실패, 노드 CPU 포화, 시스템 구성 정리

| 항목 | 내용 |
|---|---|
| 일시 | 2026-11-19 KST |
| 유형 | 장애 |
| 대상 | `squarek8s` 클러스터와 PostgreSQL 호스트 |
| 상태 | 완료 |

## 요약

SSM 값을 바꿔도 파드가 자동으로 재시작되지 않아 원인을 찾다가, ArgoCD selfHeal이 Reloader와 Argo Rollouts의 변경을 되돌리고 있었고 Datadog Agent의 SELinux 거부 기록 때문에 워커 CPU가 포화되어 있음을 확인했다. 수정 중 Reloader 재시작이 동시 재배포를 일으켜 약 2분간 인그레스 525와 dev 알림 서비스 중단이 있었다. 함께 시스템 컴포넌트를 전용 네임스페이스로 옮겼다.

## 영향

- 시크릿 변경 후 자동 재시작이 되돌려져 수동으로 파드를 지우고 있었다.
- blue-green 전환이 사실상 동작하지 않았다. 매 배포가 "Initial deploy"로 처리되어 새 파드가 Ready가 되기 전에 이전 파드가 내려갔다.
- 02:08:48부터 약 1~2분 `mllm.kr`과 `argocd.sqr.kr`이 525를 반환했고, `notification-backend`(dev)는 약 2분간 중단됐다.

## 타임라인

| 시각 (KST) | 내용 |
|---|---|
| 01:41:56 | `honami`에서 Reloader가 환경변수를 넣어 새 ReplicaSet이 생기고, 8초 뒤(01:42:04) selfHeal sync가 이를 지움 |
| 02:07경 | Reloader 전략을 바꾸는 커밋이 반영되어 Reloader가 재시작. `reloadOnCreate`와 `syncAfterRestart`가 켜져 있어 `honami`와 `notification-backend`가 동시에 재배포됨 |
| 02:08:48 | 여유가 없던 `10.20.1.58`에 파드 3개가 한꺼번에 떠 kubelet이 약 1~2분 응답하지 못함. Envoy 프록시가 이 노드에만 있어 인그레스 525 |
| 이후 | `syncAfterRestart: false`로 바꾼 뒤 Reloader를 두 번 더 재시작했을 때 재배포 없음 |

## 배경과 원인

### ArgoCD selfHeal이 다른 컨트롤러의 변경을 되돌림

- Reloader 기본 전략(`env-vars`)은 Rollout의 Pod template에 `STAKATER_*` 환경변수를 넣는다. ArgoCD가 `ServerSideApply`로 `spec.template`을 소유하므로 selfHeal sync가 이를 지웠고, 새 ReplicaSet은 약 30초 만에 내려갔다.
- Service의 `spec.selector`는 통째로 교체되는 필드라 Argo Rollouts가 붙인 `rollouts-pod-template-hash`도 sync 때마다 지워졌다. 6시간 동안 `notification-backend` Service에 대한 자동 복구 sync가 20회 이상 반복됐다.
- 셀렉터에 해시가 없으면 Argo Rollouts는 매 배포를 "Initial deploy"로 처리해 새 파드가 Ready가 되기 전에 완료로 표시하고 30초 뒤 이전 파드를 내린다.
- `annotations` 전략은 이전 상태를 비교하지 않으므로 `syncAfterRestart: true`면 Reloader가 재시작할 때마다 모든 Rollout이 다시 배포된다.

### 워커 CPU 포화

- 두 워커(각 1 vCPU)의 load average가 3.6~5.3, CPU idle이 0%였다.
- `setroubleshootd`가 CPU의 20~35%를 상시 사용했고 10분에 약 4만 7천 줄의 진단 로그를 썼다. `10.20.1.108`에서는 가동 40일 중 CPU 시간 약 10일을 이 데몬이 썼고 보조 프로세스가 메모리 1.8 GB를 잡고 있었다.
- 원인은 Datadog node Agent가 `container_t` 컨텍스트로 `/host/proc`를 읽을 때마다 생기는 SELinux 거부 기록이다. SELinux는 Permissive라 실제 차단은 없었다. [DiskPressure 기록](2026-09-10-disk-pressure.md)과 같은 원인이다.

## 조치

| 커밋 | 내용 |
|---|---|
| `496c535`, `6fd9f37` | Reloader `reloadStrategy: annotations`, `syncAfterRestart: false`. ApplicationSet에 Service 해시 셀렉터와 Reloader 어노테이션 `ignoreDifferences`, `RespectIgnoreDifferences=true` |
| `3ddd0cd` | postgres 체크를 클러스터 cluster check에서 DB 호스트 Agent로 이전. 데이터 볼륨 백업 정책 추가 |
| `e086095` | Datadog node Agent를 `spc_t` SELinux 타입으로 실행 |
| `5ef9a03`, `6737ddf`, `d93d35f` | Reloader, Argo Rollouts, cert-manager, External Secrets를 `kube-system`에서 전용 네임스페이스로 이전. cert-manager `enableCertificateOwnerRef` 제거 |
| `be99ca8`, `13a8b38` | 문서 갱신 |

저장소 밖에서 한 작업:

- Terraform apply: `oci_core_volume_backup_policy.postgres`와 할당 추가. 다른 리소스 변경 없음.
- PostgreSQL 호스트: `/etc/datadog-agent/conf.d/postgres.d/conf.yaml` 작성. `honami`, `postgres` DB에 `datadog` 스키마와 `explain_statement` 함수, `honami`에 `pg_stat_statements` 확장 생성.
- 네임스페이스 이전 전에 `aws-ssm-credentials`를 `external-secrets`로, ACME 계정 키 2개를 `cert-manager`로 복사.
- `10.20.1.108`에서 `setroubleshootd` 1회 재시작.

## 검증

- dev에서 더미 SSM 파라미터를 추가·삭제했을 때 두 번 모두 Reloader가 재배포를 일으켰고 "Completed blue-green update"로 끝났으며, 이후 selfHeal sync가 없었다.
- 두 서비스의 Service에 해시 셀렉터가 유지된다.
- node Agent 재시작 이후 새 SELinux 거부 기록이 없다. 두 노드의 CPU idle은 82~85%, setroubleshoot 로그는 5분에 1줄이다.
- 호스트 Agent의 postgres 체크가 `[OK]`이고 `honami`, `square_notification` 지표가 수집된다.
- 네임스페이스 이전 후 ClusterIssuer 3개, Certificate 4개, ClusterSecretStore, ExternalSecret 6개가 모두 Ready다. `infra`의 TLS Secret 3개에서 ownerReference가 사라졌다.
- ArgoCD 앱 15개가 전부 `Synced/Healthy`, `mllm.kr`과 `argocd.sqr.kr`이 200이다.

## 결정 사항

- SELinux 거부에 대한 Datadog 알림은 만들지 않는다. 노드의 `/var/log/audit/audit.log`에 기록이 남으므로 침해 사고 때 그 기록을 확인하는 수준으로 둔다.
- External Secrets의 AWS 장기 액세스 키는 그대로 둔다. Basic 클러스터의 OIDC issuer가 `kubernetes.default.svc.cluster.local`로 비공개라 External Secrets가 지원하는 임시 자격 증명 방식을 쓸 수 없다.

## 후속 작업

- `kube-system`에 남은 예전 사본(Secret 5개, ConfigMap `reloader-meta-info`, Lease `argo-rollouts-controller-lock`) 삭제: 같은 날 완료 확인.
- 볼륨 백업 생성 확인: 첫 정기 백업이 2026-11-19 03:00 KST에 생성됨.
- Envoy 프록시 단일 노드 문제: 같은 날 `8b15afe`로 노드마다 하나씩 두도록 변경([정리 기록](2026-11-19-repo-and-cluster-cleanup.md)).
- [backlog](../backlog.md): 노드 CPU·디스크 경보, PostgreSQL 볼륨 복원 시험, square-user-api 최초 배포, DB 호스트 Datadog 태그, 보안 권장 사항(ArgoCD admin 계정, ClusterSecretStore 범위, Gateway route 허용 범위, GitHub Actions 고정, AppProject 분리).
