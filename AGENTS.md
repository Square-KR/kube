# KUBERNETES GITOPS KNOWLEDGE BASE

## OVERVIEW

Square-KR의 OCI 기반 Kubernetes GitOps 저장소다. Terraform으로 OCI OKE와 네트워크, Bastion 겸 PostgreSQL 인스턴스를 만들고 ArgoCD App-of-Apps로 클러스터 리소스를 배포한다. 인그레스는 Envoy Gateway, 애플리케이션 배포는 Argo Rollouts, 시크릿 동기화는 External Secrets + AWS SSM Parameter Store를 사용한다.

## CURRENT STRUCTURE

```text
.
├── terraform/          # OCI VCN, OKE, 워커, Bastion/DB, Block Volume
├── bootstrap/          # ArgoCD Helmfile
├── system/             # Gateway API CRD, cert-manager, Envoy Gateway, External Secrets 등
├── networking/         # 공통 Gateway, HTTPS, HTTP redirect, ArgoCD HTTPRoute
├── observability/      # Datadog operator, Agent, PostgreSQL DBM
├── projects/           # 서비스 배포 정의
├── charts/app/         # 공통 Argo Rollout 애플리케이션 Helm chart
├── docs/postgresql.md  # PostgreSQL 설치, 튜닝, 운영 및 복구
├── root.yaml           # 최상위 ArgoCD root Application
└── bootstrap.sh        # ArgoCD 설치, AWS 자격 증명 Secret, root 적용
```

`platform/`과 Valkey는 제거된 상태다.

## WHERE TO LOOK

| 작업 | 위치 | 메모 |
|---|---|---|
| OCI 인프라 수정 | `terraform/` | 원격 OCI Object Storage state 사용 |
| 클러스터 부트스트랩 | `bootstrap/`, `bootstrap.sh` | ArgoCD 설치 후 AWS SSM 자격 증명과 root 적용 |
| 루트 App-of-Apps 수정 | `root.yaml` | `**/_application.yaml`만 수집 |
| 시스템 컴포넌트 수정 | `system/` | Gateway API CRD, cert-manager, Envoy Gateway, External Secrets, Rollouts, Reloader |
| 공통 게이트웨이 수정 | `networking/gateway/` | `infra` 네임스페이스의 Gateway/HTTPRoute와 OCI LB 설정 |
| 모니터링 수정 | `observability/datadog/` | Datadog operator, DatadogAgent, PostgreSQL DBM |
| 서비스 배포 수정 | `projects/` | `notification-backend/dev`, `packet-plus-backend/dev·prod` |
| 공통 앱 템플릿 수정 | `charts/app/` | Rollout, Service, HPA, PDB |
| PostgreSQL 운영 | `docs/postgresql.md` | Terraform 이후 수동 설치·복구·튜닝 절차 |

## CURRENT INFRASTRUCTURE

| 항목 | 현재 값 |
|---|---|
| OCI 리전 | `ap-seoul-1` |
| OKE | Basic Cluster, Kubernetes `v1.33.10`, Flannel Overlay |
| 워커 | `VM.Standard.A1.Flex` 2대, 각 1 OCPU / 8 GiB / 50 GB |
| VCN | `10.20.0.0/16` |
| Public subnet | `10.20.0.0/24` |
| Worker subnet | `10.20.1.0/24` |
| Pod / Service CIDR | `10.244.0.0/16` / `10.96.0.0/16` |
| Bastion + PostgreSQL | `10.20.0.45`, 2 OCPU / 8 GiB / 부트 50 GB |
| PostgreSQL 데이터 | OCI Block Volume 50 GB, `/var/lib/postgresql` |
| 인그레스 | Envoy Gateway + OCI Flexible Load Balancer 10 Mbps + Cloudflare 전용 NSG |
| Terraform state | OCI Object Storage remote backend |

OKE 버전과 노드 이미지는 `terraform/main.tf`에 고정되어 있다. OCI에서 지원이 끝나면 지원 버전과 정확한 OKE 이미지 이름을 함께 갱신한다.

## DEPLOYMENT FLOW

| Wave | 구성 | 목적 |
|---|---|---|
| 0 | Gateway API CRD, cert-manager | Gateway 리소스와 인증서 선행 |
| 1 | `system/*` | Envoy Gateway, External Secrets, Reloader, Argo Rollouts |
| 2 | `networking/*` | Gateway와 HTTP → HTTPS redirect |
| 4 | `observability/*` | Datadog과 PostgreSQL DBM |
| 5 | `projects/*` | 서비스 워크로드 |

## REPO CONVENTIONS

### ArgoCD 파일 패턴

- `root.yaml`: 저장소 최상위 root Application
- `_application.yaml`: 도메인별 App-of-Apps 엔트리
- `application.yaml`: 단일 컴포넌트용 Application
- `applicationset.yaml`: 환경별 또는 반복 배포용 ApplicationSet

`root.yaml`는 `**/_application.yaml`만 수집한다. 각 도메인의 `_application.yaml`는 하위 `application.yaml`, `applicationset.yaml`를 수집한다.

### Namespace 규칙

- `argocd`: ArgoCD control plane
- `kube-system`: cert-manager, External Secrets, Reloader, Argo Rollouts
- `envoy-gateway-system`: Envoy Gateway controller와 proxy 설정
- `infra`: 공통 Gateway와 HTTPRoute
- `datadog`: Datadog operator와 agent
- `dev`: 개발 애플리케이션 워크로드
- `prod`: 운영 애플리케이션 워크로드

### Secret 규칙

- 클러스터는 OCI에 있지만 External Secrets backend는 AWS SSM Parameter Store다.
- 단일 `ClusterSecretStore` `aws-ssm`을 사용하며 자격 증명은 `kube-system/aws-ssm-credentials`에 둔다.
- 서비스 시크릿은 `/{env}/{service}/{KEY}` 패턴을 사용한다.
- 인프라 시크릿은 `/infrastructure/...` 경로를 사용한다.
- 사용 중인 인프라 경로는 GHCR, Cloudflare, Datadog이며 PostgreSQL DBM 비밀번호는 `/infrastructure/datadog/postgresql-password`다.
- `/infrastructure/postgresql/`와 `MAIN_IP`는 사용하지 않는다.
- GHCR pull secret은 `system/external-secrets/ghcr-pull-secret.yaml`에서 공용으로 만든다.
- YAML, Terraform, 문서에 비밀번호·토큰·개인 키를 하드코딩하지 않는다.

### 애플리케이션 배포 규칙

- 서비스 워크로드는 `Deployment` 대신 공통 chart의 Argo `Rollout`을 사용한다.
- 서비스 차이는 `projects/{service}/{env}/values.yaml`에서 오버라이드한다.
- 서비스별 환경 폴더에는 보통 `values.yaml`, `external-secret.yaml`만 두고 필요할 때만 매니페스트를 추가한다.
- 현재 서비스는 `notification-backend/dev`, `packet-plus-backend/dev·prod`다.

## POSTGRESQL AND TAILSCALE

- PostgreSQL 16은 Bastion 인스턴스에서 실행하며 `10.20.0.45:5432`를 사용한다.
- 애플리케이션 DB/역할은 `square_notification` / `notification_backend`다.
- Datadog 역할은 `square_datadog`이며 superuser가 아니다.
- 노트북용 원격 관리자 역할은 `square_admin`이다. 비밀번호는 저장소나 SSM이 아니라 로컬 macOS 키체인의 서비스 `squarek8s-postgresql`에 저장되어 있다.
- Tailscale 장치 이름은 `squarek8s-db-router`이고 `10.20.0.0/16`을 subnet route로 광고하며 승인된 상태다.
- 서버는 IPv4/IPv6 forwarding이 활성화되어 있고 PostgreSQL은 Tailscale CGNAT 대역 `100.64.0.0/10`에 TLS + SCRAM 접속을 허용한다.
- Terraform은 PostgreSQL 설치, 역할, 데이터, Tailscale을 구성하지 않는다. Bastion을 재생성하면 `docs/postgresql.md` 절차와 Tailscale 설치·route 승인을 다시 수행한다.

```bash
# 노트북에서 PostgreSQL 관리자 비밀번호 조회
security find-generic-password -a square_admin -s squarek8s-postgresql -w

# Tailscale을 통한 PostgreSQL 연결 확인
nc -vz 10.20.0.45 5432

# 서버의 Tailscale 상태 확인
ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip) \
  'sudo tailscale status'
```

## DATADOG POSTGRESQL DBM

- Datadog site는 `us5.datadoghq.com`이며 APM, 전체 컨테이너 로그, OTEL collector, cluster checks가 활성화되어 있다.
- PostgreSQL cluster check는 `10.20.0.45:5432/square_notification`에 TLS로 연결한다.
- `relations.relation_regex: .*`로 모든 relation을 자동 수집한다.
- relation, bloat, WAL, checksum metrics와 DBM이 활성화되어 있다.
- Agent 비밀번호는 ExternalSecret을 통해 `/infrastructure/datadog/postgresql-password`에서 가져온다.

## NETWORK SECURITY

- Public subnet security list는 Bastion, OKE public endpoint, Envoy LoadBalancer subnet이 공유하지만 공개 80/443 규칙은 두지 않는다.
- Envoy LoadBalancer에는 Terraform의 `squarek8s-envoy-lb-nsg`를 연결하고 Cloudflare 공식 IPv4 대역에서 오는 TCP 80/443만 허용한다.
- Envoy Service의 `oci.oraclecloud.com/security-rule-management-mode`는 `None`이다. OCI Cloud Controller가 security list에 `0.0.0.0/0` 규칙을 다시 만들지 않게 유지한다.
- Cloudflare IP 대역이 변경되면 `terraform/main.tf`의 `cloudflare_ipv4_cidrs`를 갱신한 뒤 apply한다.
- PostgreSQL 호스트는 로컬 방화벽으로 공인 5432를 차단하며 원격 관리는 Tailscale의 `10.20.0.0/16` route를 사용한다.

## ANTI-PATTERNS

| 피해야 할 것 | 대신 해야 할 것 |
|---|---|
| 빈 Terraform state로 기존 인프라 apply | 기존 OCI Object Storage backend 연결 확인 |
| 백업 없이 `terraform destroy` | PostgreSQL dump와 Block Volume 영향을 먼저 확인 |
| YAML에 시크릿 하드코딩 | ExternalSecret + AWS SSM 또는 로컬 키체인 사용 |
| 서비스 하나 때문에 `charts/app/` 직접 수정 | 먼저 `values.yaml` 오버라이드 확인 |
| 서비스별 pull secret 복제 | 공용 `ghcr-pull-secret` 재사용 |
| 루트에서 `application.yaml` 직접 추가 | 도메인별 `_application.yaml` 아래에 연결 |
| 서비스에 `Deployment` 사용 | 공통 chart의 `Rollout` 유지 |
| 운영 리소스를 `kubectl edit`로 상시 수정 | Git 변경 후 ArgoCD sync |
| 공인 IP로 PostgreSQL 5432 개방 | Tailscale route 사용 |
| Envoy Service의 NSG annotation 제거 | Cloud Controller가 공개 security list 규칙을 다시 만들 수 있으므로 NSG와 `None` 모드 유지 |

## USEFUL COMMANDS

```bash
# 기존 OCI state로 인프라 확인
cd terraform
terraform init -backend-config=backend.hcl
terraform plan

# kubeconfig
export KUBECONFIG=~/.kube/oke-squarek8s
kubectl get nodes

# 새 클러스터 GitOps 부트스트랩
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
./bootstrap.sh

# ArgoCD 상태와 UI
kubectl -n argocd get applications
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# 특정 ArgoCD 앱 sync
kubectl -n argocd patch app <app-name> -p '{"operation":{"sync":{}}}' --type merge

# Gateway와 Envoy LB 주소
kubectl get gateway -n infra

# PostgreSQL 서버 접속
ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip)
```

## REMINDERS

- 문서 언어는 한국어로 유지한다.
- 현재 kubeconfig는 `~/.kube/oke-squarek8s` 하나를 기준으로 사용한다.
- `helmfile diff`에는 `helm-diff` 플러그인이 필요하다.
- Cloudflare는 `sqr.kr`, `*.sqr.kr`, `dev-api.packet.plus`, `api.packet.plus`을 Envoy LoadBalancer 공인 IP로 proxied 처리한다.
- Envoy LoadBalancer나 Bastion을 재생성하면 공인 IP가 바뀔 수 있다. DB private IP `10.20.0.45`는 Terraform에 고정되어 있다.
- PostgreSQL 자동 백업과 HA는 현재 구성하지 않았다.
