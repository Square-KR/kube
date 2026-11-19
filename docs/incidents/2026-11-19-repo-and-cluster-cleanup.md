# 저장소와 클러스터 정리

| 항목 | 내용 |
|---|---|
| 일시 | 2026-11-19 13:00 ~ 13:10 KST |
| 유형 | 작업 |
| 대상 | `squarek8s` 클러스터, 저장소 코드·문서 |
| 상태 | 완료 |

## 요약

실제 상태와 저장소를 비교해 클러스터에 남은 수동 리소스와 쓰지 않는 구성 요소를 지우고, 코드·문서의 중복과 낡은 내용을 정리했다. Envoy 프록시를 노드마다 하나씩 두도록 바꾼 뒤 업그레이드 때 만든 임시 ReplicaSet을 지웠다. 서비스 중단은 없었다.

## 배경과 원인

작업 전 확인한 상태:

- Terraform plan "No changes", ArgoCD 앱 15개 `Synced/Healthy`, PostgreSQL DB·역할·pg_hba·Tailscale은 문서와 일치했다.
- `envoy-gateway-system`에 2026-10-09 OKE 업그레이드 때 만든 ReplicaSet `oke-upgrade-envoy-surge`가 남아 있었다. 라벨이 LB Service selector와 같아 실제 트래픽을 받고 있었지만, 정식 프록시와 같은 노드 `10.20.1.58`에 있어 이중화 효과가 없었다.
- Envoy Service는 `externalTrafficPolicy: Local`이라 프록시가 없는 노드는 OCI LB 헬스체크(healthCheckNodePort `30325`)에서 빠진다.
- 초기 설치 때 Envoy Gateway 차트에서 들어온 Gateway API 실험 채널 CRD(`xbackendtrafficpolicies`, `xmeshes`, v1.5.1)가 인스턴스 없이 남아 있었다. Envoy Gateway는 이 그룹을 감시하지 않는다.
- `kube-system`을 제외한 시스템 컨테이너 대부분에 resource requests가 없어, `10.20.1.58`은 requests 기준 CPU 80%(680m)인데도 실제 부하를 스케줄러가 반영하지 못했다.
- ArgoCD `dex-server`(SSO 미사용)와 `notifications-controller`(알림 설정 없음), ClusterIssuer `letsencrypt-cloudflare-staging`(사용하는 Certificate 0개), Datadog cluster checks(실행 중인 체크 0개)를 쓰지 않고 있었다.

## 조치

| 커밋 | 내용 |
|---|---|
| `8b15afe` | EnvoyProxy `replicas: 2`, 노드별 분산(`DoNotSchedule`, `matchLabelKeys: [pod-template-hash]`로 임시 파드 제외), PDB `minAvailable: 1` |
| `c215242` | 공통 chart에서 쓰지 않는 HPA·PDB 템플릿과 값 제거. 클러스터에 Metrics API가 없어 HPA는 동작하지 않았다 |
| `9cedb9f` | staging ClusterIssuer 제거, Datadog `clusterChecks.enabled: false`, Argo Rollouts 컨트롤러 1개 |
| `2069bc7` | Pod Security `*-version` 라벨 제거. 클러스터 버전의 정책을 따른다 |
| `56944f8` | deploy-image가 다른 서비스 배포와 겹쳐 push가 거부되면 rebase 후 재시도 |
| `a66eab3` | push·PR마다 chart 렌더링, kubeconform, shellcheck, GHCR 정리 테스트를 실행하는 `validate` 워크플로 |
| `8e3362b` | 불필요한 주석 제거, 영어 주석 한국어화, Terraform 보안 목록 주석을 현재 상태에 맞게 수정 |
| `d2b3734` | ArgoCD `dex`, `notifications` 비활성화 |

저장소 밖에서 한 작업:

- 정식 Envoy 프록시 2개가 서로 다른 노드에 뜨고 OCI LB backend set `TCP-80`, `TCP-443`이 모두 OK인 것을 확인한 뒤 ReplicaSet `oke-upgrade-envoy-surge`를 삭제했다.
- CRD `xbackendtrafficpolicies.gateway.networking.x-k8s.io`, `xmeshes.gateway.networking.x-k8s.io`를 삭제했다.
- `helm diff`로 dex·notifications 리소스 제거와 남는 컴포넌트의 checksum 변경만 있음을 확인하고 ArgoCD Helm 릴리스를 revision 2로 올렸다.
- ArgoCD prune 뒤 남은 ACME 계정 Secret `cert-manager/letsencrypt-cloudflare-staging`을 삭제했다.

## 검증

- Envoy 프록시가 `10.20.1.108`, `10.20.1.58`에 하나씩 있고 PDB가 생성됐다. 두 노드의 healthCheckNodePort가 200을 반환했다.
- `https://mllm.kr/api/health`, `https://argocd.sqr.kr`이 200이다.
- ArgoCD 앱 15개가 `Synced/Healthy`이고, `dev`, `prod` 네임스페이스에는 `restricted` 라벨만 남았다.
- `validate` 워크플로에서 렌더링 결과 4개와 매니페스트 30개가 모두 스키마 검증을 통과했다.

## 결정 사항

- `kube-system`의 cert-manager Lease는 지금 cert-manager가 리더 선출에 쓰는 것이라 남긴다.
- Datadog `DD_IGNORE_AUTOCONF`의 `redisdb`는 `argocd-redis` 자동 감지를 막으므로 남긴다.
- 서비스별 ApplicationSet 통합은 템플릿의 `resources-finalizer` 때문에 prod 리소스가 삭제될 위험이 있어 이번에 하지 않았다.

## 후속 작업

[backlog](../backlog.md): 시스템 파드 resource requests, OCI 보안 목록 잔여 규칙, ApplicationSet 통합 검토.
