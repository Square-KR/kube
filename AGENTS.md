# KUBERNETES GITOPS KNOWLEDGE BASE

## OVERVIEW

Square-KR Kubernetes GitOps monorepo. ArgoCD App-of-Apps로 클러스터 리소스를 배포하며, 네트워킹은 Cilium Gateway API, 애플리케이션 배포는 Argo Rollouts, 시크릿 관리는 External Secrets + AWS SSM Parameter Store를 사용한다.

## CURRENT STRUCTURE

```text
.
├── bootstrap/          # 초기 부트스트랩: Cilium, ArgoCD
├── system/             # 공통 시스템 컴포넌트: cert-manager, external-secrets, argo-rollouts, reloader
├── networking/         # Gateway API 및 공통 HTTP redirect
├── platform/           # 공용 데이터 레이어: Valkey
├── observability/      # Datadog operator + DatadogAgent
├── projects/           # 서비스 배포 정의 (현재 notification-backend 중심)
├── charts/app/         # 공통 애플리케이션 Helm chart
├── root.yaml           # 최상위 ArgoCD root Application
└── bootstrap.sh        # 새 클러스터 초기 설치 스크립트
```

## WHERE TO LOOK

| 작업 | 위치 | 메모 |
|------|------|------|
| 클러스터 부트스트랩 수정 | `bootstrap/`, `bootstrap.sh` | Cilium/ArgoCD 설치 순서와 초기 secret 생성 |
| 루트 App-of-Apps 수정 | `root.yaml` | `**/_application.yaml`만 수집 |
| 시스템 컴포넌트 수정 | `system/` | cert-manager, external-secrets, argo-rollouts, reloader |
| 공통 게이트웨이 수정 | `networking/gateway/` | `infra` 네임스페이스에 Gateway/HTTPRoute 배포 |
| 공용 캐시 수정 | `platform/valkey/` | `dev`, `prod` 환경별 ApplicationSet |
| 모니터링 수정 | `observability/datadog/` | Datadog operator + `DatadogAgent` + ExternalSecret |
| 서비스 배포 수정 | `projects/` | 현재 `notification-backend` ApplicationSet 및 env 값 |
| 공통 앱 템플릿 수정 | `charts/app/` | Rollout/Service/HPA/PDB 공통 chart |

## DEPLOYMENT FLOW

ArgoCD sync wave 순서는 다음과 같다.

| Wave | 구성 | 목적 |
|------|------|------|
| 0 | `system/cert-manager` | 인증서 및 Gateway TLS 선행 |
| 1 | `system/*` | External Secrets, Reloader, Argo Rollouts |
| 2 | `networking/*` | Gateway 및 HTTP -> HTTPS redirect |
| 3 | `platform/*` | 공용 데이터 계층 |
| 4 | `observability/*` | Datadog 수집기 |
| 5 | `projects/*` | 서비스 배포 |

## REPO CONVENTIONS

### ArgoCD 파일 패턴

- `root.yaml`: 저장소 최상위 root Application
- `_application.yaml`: 상위 App-of-Apps 엔트리
- `application.yaml`: 단일 컴포넌트용 Application
- `applicationset.yaml`: 환경별 또는 반복 배포용 ApplicationSet

주의:
- `root.yaml`는 `**/_application.yaml`만 수집한다.
- 각 도메인 폴더의 `_application.yaml`는 하위의 `application.yaml`, `applicationset.yaml`를 수집한다.

### Namespace 규칙

- `argocd`: ArgoCD control plane
- `kube-system`: Cilium, cert-manager, external-secrets, reloader, argo-rollouts
- `infra`: Gateway API 공통 리소스
- `datadog`: Datadog operator 및 agent
- `dev`, `prod`: 애플리케이션/플랫폼 워크로드

### Secret 규칙

- AWS SSM Parameter Store를 단일 `ClusterSecretStore`(`aws-ssm`)로 참조한다.
- 서비스 시크릿은 `/{env}/{service}/{KEY}` 패턴을 사용한다.
- 인프라 공용 시크릿은 `/infrastructure/...` 경로를 사용한다.
- GHCR pull secret은 서비스별 파일이 아니라 `system/external-secrets/ghcr-pull-secret.yaml`에서 생성한다.

### 애플리케이션 배포 규칙

- 서비스 워크로드는 `Deployment` 대신 Argo `Rollout`을 사용한다.
- 공통 배포 로직은 `charts/app`에 두고, 서비스 차이는 `projects/{service}/{env}/values.yaml`에서 오버라이드한다.
- 서비스별 env 파일에는 보통 `values.yaml`, `external-secret.yaml`이 있고, 필요할 때만 추가 매니페스트를 둔다.

## CURRENT STATE NOTES

- 현재 `projects/`에는 `notification-backend` 배포 정의가 남아 있다.
- 현재 서비스 환경 디렉터리는 `projects/notification-backend/dev/`만 존재한다.
- 공통 게이트웨이는 `sqr.kr` apex와 `*.sqr.kr` wildcard HTTPS listener를 제공한다.
- Datadog은 `us5.datadoghq.com` 사이트를 사용하며 APM, 로그 수집, OTEL collector를 활성화한다.
- Cilium은 Gateway API와 Hubble을 활성화한 상태로 부트스트랩된다.

## ANTI-PATTERNS

| 피해야 할 것 | 대신 해야 할 것 |
|--------------|----------------|
| YAML에 시크릿 직접 하드코딩 | ExternalSecret + AWS SSM 사용 |
| 서비스 하나 때문에 `charts/app/` 직접 수정 | 먼저 `values.yaml` 오버라이드 가능 여부 확인 |
| 서비스별 `pull-secret.yaml` 복제 | 공용 `ghcr-pull-secret` 재사용 |
| 루트에서 `application.yaml`를 직접 추가 | 도메인별 `_application.yaml` 아래에 연결 |
| 서비스 워크로드를 `Deployment`로 작성 | 공통 chart의 `Rollout` 경로 유지 |

## USEFUL COMMANDS

```bash
# 새 클러스터 부트스트랩
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
./bootstrap.sh

# ArgoCD UI 접속
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# 특정 ArgoCD 앱 강제 sync
kubectl -n argocd patch app <app-name> -p '{"operation":{"sync":{}}}' --type merge

# Cilium 상태 확인
kubectl -n kube-system exec -it ds/cilium -- cilium status
```

## REMINDERS

- 문서 언어는 한국어 기준으로 유지한다.
- `helmfile diff`를 쓰려면 `helm-diff` 플러그인이 필요하다.
- Cloudflare proxied 구성을 전제로 NLB source IP 보존은 비활성화한다.
