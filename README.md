# Square-KR Kubernetes

OCI OKE와 ArgoCD App-of-Apps로 운영하는 Kubernetes GitOps 저장소다. 저장소 규칙은 [AGENTS.md](AGENTS.md), 문서 목록과 템플릿은 [문서 안내](docs/README.md)에 있다.

## 현재 구성

버전·사양·주소의 기준 문서다. 바뀌면 이 표를 먼저 고친다.

| 구성 | 사양 |
|---|---|
| 리전 | OCI `ap-seoul-1`, AWS SSM은 `ap-northeast-2` |
| OKE | Basic Cluster, Kubernetes `v1.37.1`, Flannel Overlay |
| 워커 | `VM.Standard.A1.Flex` 2대, 각 1 OCPU / 8 GiB / 50 GB (루트 파일시스템 약 30 GiB) |
| 네트워크 | VCN `10.20.0.0/16`, public subnet `10.20.0.0/24`, worker subnet `10.20.1.0/24`, Pod `10.244.0.0/16`, Service `10.96.0.0/16` |
| Bastion + PostgreSQL | `VM.Standard.A1.Flex` 1대, 2 OCPU / 8 GiB / 부트 50 GB, `10.20.0.45`, PostgreSQL 16 |
| PostgreSQL 데이터 | OCI Block Volume 50 GB, 매일 03:00 KST 증분 백업 7일·일요일 백업 4주 보존 |
| 인그레스 | Envoy Gateway, 프록시 2개(노드별 1개) + OCI Flexible Load Balancer 10 Mbps, Cloudflare IPv4만 허용하는 NSG |
| 도메인 | Cloudflare proxied `sqr.kr`, `*.sqr.kr`, `mllm.kr` |
| 모니터링 | Datadog `us5.datadoghq.com`. 클러스터 Agent(APM, 컨테이너 로그, OTEL)와 DB 호스트 Agent(호스트 지표, PostgreSQL DBM) |
| 원격 DB 관리 | Tailscale subnet router `10.20.0.0/16` |
| Terraform state | OCI Object Storage 원격 backend |
| 서비스 | `notification-backend`(dev), `honami`(prod). 목록은 [projects/AGENTS.md](projects/AGENTS.md) |

## 새 클러스터 구축

아래 순서대로 진행한다. OKE만 재생성하고 기존 PostgreSQL과 AWS SSM을 유지하는 경우 이 절차만으로 충분하다. PostgreSQL 인스턴스까지 새로 만들면 DB 역할·스키마·SSM 값은 별도로 복원해야 한다.

### 1. 사전 준비

- OCI CLI `k8s-tf` 프로필
- Terraform, OCI CLI, `kubectl`, `helmfile`, `helm-diff` 플러그인
- 암호 없는 전용 SSH 키 `~/.ssh/squarek8s`, `~/.ssh/squarek8s.pub`
- OCI Object Storage의 Terraform state 버킷
- AWS SSM 접근 권한이 있는 액세스 키
- AWS SSM의 기존 인프라 시크릿
  - `/infrastructure/ghcr/username`
  - `/infrastructure/ghcr/token`
  - `/infrastructure/cloudflare/api-token`
  - `/infrastructure/datadog/api-key`
  - `/infrastructure/datadog/postgresql-password`

```bash
oci iam region list --profile k8s-tf >/dev/null
chmod 600 ~/.ssh/squarek8s
```

### 2. OCI 인프라 생성

```bash
cd terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

`backend.hcl`에는 state 버킷 정보를, `terraform.tfvars`에는 compartment OCID, 관리자 공인 IP `/32`, `~/.ssh/squarek8s.pub`를 설정한다.

```bash
terraform init -backend-config=backend.hcl
terraform plan -out=squarek8s.tfplan
terraform apply squarek8s.tfplan
```

기존 환경을 이어서 관리할 때는 반드시 기존 Object Storage state를 사용한다. 빈 state로 실행하면 동일 자원을 새로 만들려고 한다.

Envoy LoadBalancer NSG를 새로 만들었으면 OCID를 `networking/gateway/envoy.yaml`의 `oci.oraclecloud.com/oci-network-security-groups`에 반영하고 push한다. 이 값이 틀리면 LoadBalancer가 Cloudflare 트래픽을 받지 못한다.

```bash
terraform output -raw envoy_lb_nsg_id
```

### 3. kubeconfig 생성

```bash
$(terraform output -raw kubeconfig_command)
export KUBECONFIG=~/.kube/oke-squarek8s
kubectl get nodes
```

### 4. PostgreSQL 준비

[PostgreSQL 런북](docs/runbooks/postgresql.md)의 설치, 튜닝, 역할, 서비스 DB, Tailscale 절차를 수행하고, 기존 데이터가 있으면 애플리케이션을 배포하기 전에 복원한다. DB 역할·스키마·SSM 값은 Terraform이나 ArgoCD가 만들지 않는다.

### 5. GitOps 부트스트랩

저장소 루트에서 실행한다.

```bash
export KUBECONFIG=~/.kube/oke-squarek8s
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
./bootstrap.sh
```

### 6. DNS와 최종 확인

Envoy LoadBalancer의 공인 IP를 확인한 뒤 Cloudflare의 `sqr.kr`, `*.sqr.kr`, `mllm.kr` proxied A 레코드를 변경한다.

```bash
kubectl get gateway -n infra
kubectl get applications -n argocd
kubectl get nodes
kubectl get pods -A
```

모든 ArgoCD Application이 `Synced/Healthy`이고 서비스 readiness probe가 성공하면 구축이 끝난다.

## 재구축 시 주의사항

- Object Storage의 Terraform state는 인프라 목록이지 PostgreSQL 데이터 백업이 아니다.
- `terraform destroy`는 PostgreSQL Block Volume도 제거한다. 필요한 데이터는 먼저 `pg_dump`로 백업한다.
- OKE Kubernetes 버전과 노드 이미지는 `terraform/main.tf`에 고정되어 있다. OCI에서 더 이상 지원하지 않으면 [OKE 업그레이드 런북](docs/runbooks/oke-upgrade.md)대로 올린다.
- Bastion 공인 IP와 Envoy LoadBalancer IP는 재생성 시 바뀔 수 있다. PostgreSQL 내부 주소 `10.20.0.45`는 Terraform에 고정되어 있다.
- PostgreSQL 데이터 볼륨은 Terraform의 백업 정책으로 매일 백업한다. 논리 백업, PITR, HA는 구성하지 않았고 볼륨 복원은 아직 시험하지 않았다.
- 워커 루트 파일시스템은 약 30 GiB라 `/var/log/messages`가 쌓이면 DiskPressure가 난다. `terraform/worker-init.sh`가 node pool user_data로 보존 정책을 설치하고, 실행 중인 노드에는 `sudo bash -s -- --logs-only < terraform/worker-init.sh`로 적용한다. 배경은 [DiskPressure 기록](docs/incidents/2026-09-10-disk-pressure.md)에 있다.

## 서비스 시크릿 등록

서비스 시크릿은 `/{env}/{service}/{KEY}` 경로의 SSM SecureString으로 둔다. `.env` 파일을 한 번에 올릴 때는 다음 스크립트를 사용한다.

```bash
PREFIX=/dev/notification-backend ENV_FILE=.env scripts/env-to-ssm.sh
```

## 운영 접속

```bash
ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip)
kubectl port-forward svc/argocd-server -n argocd 8080:443
security find-generic-password -a square_admin -s squarek8s-postgresql -w | pbcopy   # PostgreSQL 관리자 비밀번호를 클립보드로
nc -vz 10.20.0.45 5432                                                              # Tailscale 경유 DB 연결
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```
