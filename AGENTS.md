# KUBERNETES GITOPS KNOWLEDGE BASE

## OVERVIEW

Square-KR의 OCI 기반 Kubernetes GitOps 저장소다. Terraform으로 OCI OKE, 네트워크, Bastion 겸 PostgreSQL 인스턴스를 만들고 ArgoCD App-of-Apps로 클러스터 리소스를 배포한다. 인그레스는 Envoy Gateway, 애플리케이션 배포는 Argo Rollouts, 시크릿 동기화는 External Secrets + AWS SSM Parameter Store를 쓴다. 현재 버전·사양·주소는 [README](README.md)의 "현재 구성"을 본다.

## STRUCTURE

```text
.
├── .github/            # PR 템플릿, CODEOWNERS
│   └── workflows/      # validate(매니페스트·스크립트 검증), deploy-image(이미지 태그 갱신), cleanup-ghcr(GHCR 정리)
├── terraform/          # OCI VCN, OKE, 워커(worker-init.sh user_data), Bastion/DB, Block Volume과 백업 정책
├── bootstrap/          # ArgoCD Helmfile. GitOps 밖에서 수동 적용
├── system/             # Gateway API CRD, cert-manager, Envoy Gateway, External Secrets, Argo Rollouts, Reloader
├── networking/         # 공통 Gateway, EnvoyProxy·OCI LB 설정, HTTP redirect, ArgoCD HTTPRoute
├── observability/      # Datadog operator, DatadogAgent
├── projects/           # 서비스 배포 정의
├── charts/app/         # 공통 Argo Rollout chart
├── scripts/            # 매니페스트 검증, GHCR 정리와 테스트, .env → SSM 업로드
├── docs/               # 문서 안내와 템플릿, 런북, 기록, backlog
├── root.yaml           # 최상위 ArgoCD root Application
└── bootstrap.sh        # ArgoCD 설치, AWS 자격 증명 Secret, root 적용
```

## WHERE TO LOOK

| 작업 | 위치 | 참고 |
|---|---|---|
| OCI 인프라 | `terraform/` | 원격 OCI Object Storage state |
| 워커 노드 OS 설정 | `terraform/worker-init.sh` | OKE 기본 초기화 후 messages logrotate 정책 설치 |
| OKE 업그레이드 | `terraform/main.tf` | [OKE 업그레이드 런북](docs/runbooks/oke-upgrade.md) |
| 클러스터 부트스트랩 | `bootstrap/`, `bootstrap.sh` | README "새 클러스터 구축" |
| 시스템 컴포넌트 | `system/` | |
| Gateway, Envoy 프록시, LB | `networking/gateway/` | `infra` Gateway, `envoy-gateway-system` EnvoyProxy |
| 모니터링 | `observability/datadog/` | PostgreSQL 지표는 DB 호스트 Agent가 수집 |
| 서비스 배포 | `projects/` | [projects/AGENTS.md](projects/AGENTS.md) |
| 공통 앱 템플릿 | `charts/app/` | [charts/app/AGENTS.md](charts/app/AGENTS.md) |
| PostgreSQL, Tailscale, DB 호스트 Datadog Agent | 호스트 수동 구성 | [PostgreSQL 런북](docs/runbooks/postgresql.md) |
| 이미지 배포 자동화 | `.github/workflows/deploy-image.yml` | `projects/{service}/{env}/values.yaml`의 `image.version` 갱신 |
| GHCR 정리 | `.github/workflows/cleanup-ghcr.yml`, `scripts/cleanup-ghcr.sh` | 배포 중 태그, `latest`, 태그 없는 child manifest 보존 |
| SSM 시크릿 업로드 | `scripts/env-to-ssm.sh` | `.env`를 `/{env}/{service}/{KEY}` SecureString으로 저장 |
| 남은 일, 과거 장애·작업 | `docs/backlog.md`, `docs/incidents/` | [문서 안내](docs/README.md) |

## DEPLOYMENT FLOW

`root`가 도메인별 App-of-Apps를 wave 순서로 만든다.

| Wave | 구성 | 목적 |
|---|---|---|
| 1 | `system` | 클러스터 공통 컴포넌트 |
| 2 | `networking` | Gateway와 HTTP → HTTPS redirect |
| 4 | `observability` | Datadog |
| 5 | `projects` | 서비스 워크로드 |

`system` 안에서는 Gateway API CRD, cert-manager, Argo Rollouts, Reloader가 wave 0, Envoy Gateway와 External Secrets가 wave 1이다.

## REPO CONVENTIONS

### ArgoCD 파일 패턴

- `root.yaml`: 최상위 root Application. `**/_application.yaml`만 수집한다.
- `_application.yaml`: 도메인별 App-of-Apps. 하위 `application.yaml`, `applicationset.yaml`을 수집한다.
- `application.yaml`: 단일 컴포넌트 Application
- `applicationset.yaml`: 환경별 또는 반복 배포 ApplicationSet

### 네임스페이스

| 네임스페이스 | 용도 |
|---|---|
| `argocd` | ArgoCD control plane |
| `cert-manager` | cert-manager, ClusterIssuer가 쓰는 `cloudflare-api-token`과 ACME 계정 키 |
| `external-secrets` | External Secrets와 `aws-ssm-credentials` |
| `argo-rollouts`, `reloader` | 각 컨트롤러 |
| `envoy-gateway-system` | Envoy Gateway controller와 프록시 |
| `infra` | 공통 Gateway와 HTTPRoute |
| `datadog` | Datadog operator와 Agent |
| `dev`, `prod` | 서비스 워크로드 |

### 시크릿

- External Secrets backend는 AWS SSM Parameter Store이고, 단일 `ClusterSecretStore` `aws-ssm`의 자격 증명은 `external-secrets/aws-ssm-credentials`에 있다.
- 서비스 시크릿은 `/{env}/{service}/{KEY}`, 인프라 시크릿은 `/infrastructure/{ghcr,cloudflare,datadog}/...`를 쓴다. `/infrastructure/datadog/postgresql-password`는 DB 호스트 Agent 설정에만 쓴다.
- GHCR pull secret은 `system/external-secrets/ghcr-pull-secret.yaml`이 라벨 `square-kr.io/ghcr-pull-secret: "true"`가 붙은 네임스페이스에 만든다.
- PostgreSQL 관리자 `square_admin`의 비밀번호는 노트북 macOS 키체인 서비스 `squarek8s-postgresql`에만 있다.

### 애플리케이션 배포

- 서비스 워크로드는 공통 chart의 Argo `Rollout`(blue-green)으로 배포한다. 서비스 차이는 `projects/{service}/{env}/values.yaml`에서 오버라이드한다.
- Reloader는 `annotations` 전략, `syncAfterRestart: false`로 둔다. `true`면 Reloader가 재시작할 때마다 모든 Rollout이 다시 배포된다.
- 서비스 규칙과 새 서비스 체크리스트는 [projects/AGENTS.md](projects/AGENTS.md)에 있다.

## 불변 조건

바꾸면 장애로 이어지는 값과 설정이다.

- PostgreSQL 주소 `10.20.0.45:5432`는 Terraform에 고정되어 있다. 공인 5432는 열지 않고 원격 관리는 Tailscale subnet route `10.20.0.0/16`(호스트 `squarek8s-db-router`, MagicDNS `db-router-01`)을 쓴다.
- Bastion `source_details[0].source_id`의 `ignore_changes`를 유지한다. 빼면 부트 볼륨이 교체되어 PostgreSQL, Tailscale, Datadog 호스트 Agent 설치가 사라진다.
- Envoy LB에는 Terraform의 `squarek8s-envoy-lb-nsg`를 붙이고, NSG는 Cloudflare IPv4 대역의 TCP 80/443만 허용한다. Envoy Service의 `oci.oraclecloud.com/security-rule-management-mode: "None"`을 유지해 Cloud Controller가 security list에 `0.0.0.0/0` 규칙을 만들지 않게 한다. Public subnet security list에는 공개 80/443 규칙을 두지 않는다.
- Envoy Service는 `externalTrafficPolicy: Local`이다. 프록시가 없는 노드는 LB에서 빠지므로 EnvoyProxy의 노드별 분산과 PDB를 유지한다.
- Datadog node Agent는 `spc_t` SELinux 타입으로 실행한다. 빼면 워커의 setroubleshootd가 거부 기록을 분석하느라 1 vCPU를 대부분 쓴다.
- `terraform/worker-init.sh`의 OKE 초기화 부분을 유지한다. 빼면 새 노드가 클러스터에 조인하지 못한다.
- ApplicationSet의 `ignoreDifferences`와 `RespectIgnoreDifferences=true`를 유지한다.

## 코드 작성 규칙

- 주석은 코드만으로 알 수 없는 이유나 제약에만 한국어로 쓴다. 코드를 다시 말하는 주석, 변경 이력, 작업 상태는 쓰지 않는다.
- 비밀번호, 토큰, 개인 키를 YAML, Terraform, 스크립트, 문서에 넣지 않는다. ExternalSecret + SSM 또는 로컬 키체인을 쓴다.
- 외부 Helm chart와 Git source는 `targetRevision`을 정확한 버전으로 고정한다. 이 저장소를 가리키는 source만 `HEAD`를 쓴다.
- 셸 스크립트는 bash로 쓰고 `set -euo pipefail`을 켜며 `shellcheck -S warning`을 통과해야 한다. `worker-init.sh`는 OKE 초기화 부분이 실패를 직접 처리하므로 `set -euo pipefail`을 그 뒤에 둔다.
- Terraform은 `terraform fmt`를 지키고, 기존 state로 `plan`을 확인한 뒤 apply한다.
- 매니페스트나 chart를 고치면 `scripts/validate-manifests.sh`를 실행한다(`helm`, `kubeconform` 필요). 같은 검사가 push·PR마다 `validate` 워크플로로 돈다.
- 커밋 메시지는 `type: 영어 소문자 요약` 형식이다. type은 `feat`, `fix`, `refactor`, `chore`, `docs`, `ci`를 쓰고, 봇 커밋은 `chore(bot):`을 쓴다.
- PR 본문은 [PR 템플릿](.github/pull_request_template.md)의 절 순서대로 쓰고 해당하지 않는 절과 항목은 지운다. 제목은 커밋 메시지와 같은 형식이다. squash merge 커밋 제목이 된다.

## 문서 작성 규칙

- 문서는 한국어로 쓰고 [문서 안내](docs/README.md)의 종류별 템플릿과 작성 규칙을 따른다.
- 현재 값은 README "현재 구성"과 PostgreSQL 런북 "적용 구성"에만 쓰고 다른 곳은 링크한다.
- 기록은 그날의 사실만 담는다. 남은 일은 `docs/backlog.md`에 등록한다.

## 함께 바꿀 것

| 바꾸는 것 | 함께 바꿀 곳 |
|---|---|
| OKE 버전·노드 이미지 | `terraform/main.tf`의 `kubernetes_version`, `oke_image_name`, README "현재 구성". [런북](docs/runbooks/oke-upgrade.md) 절차를 따른다 |
| Envoy LB NSG 재생성 | `terraform output -raw envoy_lb_nsg_id` 값을 `networking/gateway/envoy.yaml`에 반영 |
| Cloudflare IP 대역 | `terraform/main.tf`의 `cloudflare_ipv4_cidrs` 후 apply |
| 새 도메인 | `networking/gateway/gateway.yaml` listener, Cloudflare proxied 레코드, README |
| Envoy Gateway 차트 버전 | `crds.enabled: false`라 `gateway.envoyproxy.io` CRD를 ArgoCD가 관리하지 않는다. 같은 버전의 CRD를 먼저 수동 적용한다 |
| Gateway API 버전 | `system/gateway-api-crds/application.yaml`. Envoy Gateway가 지원하는 버전인지 확인한다 |
| ArgoCD 설정 | `bootstrap/argocd/values.yaml` 수정 후 `helm diff`로 확인하고 `helmfile apply`. ArgoCD는 스스로를 관리하지 않는다 |
| 서비스 DB 추가 | PostgreSQL 런북의 서비스 DB 추가 절차: SSM, Datadog `include`, `datadog` 스키마, "적용 구성" 표 |
| 서비스·환경 추가 | [projects/AGENTS.md](projects/AGENTS.md) 체크리스트 |
| Bastion 재생성 | PostgreSQL 런북 전체를 다시 수행. 공인 IP가 바뀔 수 있다 |
| 워커 노드 교체 | 새 노드 부트 볼륨은 VPU 10이다. [OKE 업그레이드 런북](docs/runbooks/oke-upgrade.md) 4단계대로 CLI로 120으로 올린다 |
| Envoy LB 재생성 | 공인 IP가 바뀔 수 있으므로 Cloudflare 레코드 갱신 |

## ANTI-PATTERNS

| 피해야 할 것 | 대신 할 것 |
|---|---|
| 빈 Terraform state로 기존 인프라 apply | 기존 OCI Object Storage backend 연결 확인 |
| 백업 없이 `terraform destroy` | PostgreSQL `pg_dump`와 Block Volume 영향을 먼저 확인 |
| 서비스 하나 때문에 `charts/app` 수정 | `values.yaml` 오버라이드 |
| 서비스에 `Deployment`나 `kustomization.yaml` 추가 | 공통 chart의 `Rollout`. 이미지 워크플로는 `values.yaml`의 `image.version`만 고친다 |
| 서비스별 pull secret 복제 | 공용 `ghcr-pull-secret` |
| 루트에 `application.yaml` 직접 추가 | 도메인별 `_application.yaml` 아래에 둔다 |
| 운영 리소스를 `kubectl edit`·수동 생성으로 상시 수정 | Git 변경 후 ArgoCD sync. 작업 중 임시로 만든 리소스는 작업이 끝나면 지우고 기록에 남긴다 |

## USEFUL COMMANDS

```bash
export KUBECONFIG=~/.kube/oke-squarek8s
kubectl -n argocd get applications
kubectl -n argocd patch app <app-name> -p '{"operation":{"sync":{}}}' --type merge

cd terraform && terraform init -backend-config=backend.hcl && terraform plan

ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip)

scripts/validate-manifests.sh
scripts/test-cleanup-ghcr.sh
```
