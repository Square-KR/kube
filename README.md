# Square-KR Kubernetes

OCI OKE와 ArgoCD App-of-Apps로 운영하는 Kubernetes GitOps 저장소다.

## 현재 구성

| 구성 | 사양 |
|---|---|
| OKE | Basic Cluster, Flannel CNI |
| 워커 | `VM.Standard.A1.Flex` 2대, 각 1 OCPU / 8 GiB / 50 GB |
| Bastion + PostgreSQL | `VM.Standard.A1.Flex` 1대, 2 OCPU / 8 GiB / 부트 50 GB |
| PostgreSQL 데이터 | OCI Block Volume 50 GB |
| 인그레스 | Envoy Gateway + OCI Flexible Load Balancer |
| Terraform state | OCI Object Storage 원격 backend |

## 새 클러스터 구축

아래 순서대로 진행한다. OKE만 재생성하고 기존 PostgreSQL과 AWS SSM을 유지하는 경우 이 절차만으로 충분하다. PostgreSQL 인스턴스까지 새로 만들면 DB 역할·스키마·SSM 값은 별도로 복원해야 한다.

### 1. 사전 준비

- OCI CLI `k8s-tf` 프로필
- Terraform, OCI CLI, `kubectl`, `helmfile`
- 암호 없는 전용 SSH 키 `~/.ssh/squarek8s`, `~/.ssh/squarek8s.pub`
- OCI Object Storage의 Terraform state 버킷
- AWS SSM 접근 권한이 있는 액세스 키
- AWS SSM의 기존 인프라 시크릿
  - `/infrastructure/ghcr/username`
  - `/infrastructure/ghcr/token`
  - `/infrastructure/cloudflare/api-token`
  - `/infrastructure/datadog/api-key`

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

### 3. kubeconfig 생성

```bash
$(terraform output -raw kubeconfig_command)
export KUBECONFIG=~/.kube/oke-squarek8s
kubectl get nodes
```

### 4. PostgreSQL 준비

[PostgreSQL 운영 문서](docs/postgresql.md)의 신규 설치와 튜닝 절차를 수행하고, 기존 데이터가 있으면 애플리케이션을 배포하기 전에 복원한다. DB 역할·스키마·SSM 값 생성은 이 저장소에서 관리하지 않는다.

### 5. GitOps 부트스트랩

저장소 루트에서 실행한다.

```bash
export KUBECONFIG=~/.kube/oke-squarek8s
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
./bootstrap.sh
```

### 6. DNS와 최종 확인

Envoy LoadBalancer의 공인 IP를 확인한 뒤 Cloudflare의 `sqr.kr`, `*.sqr.kr`, `api.packet.plus` proxied A 레코드를 변경한다.

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
- OKE Kubernetes 버전과 노드 이미지는 `terraform/main.tf`에 고정되어 있다. OCI에서 더 이상 지원하지 않으면 현재 지원 버전과 이미지로 갱신한 뒤 plan을 확인한다.
- Bastion 공인 IP와 Envoy LoadBalancer IP는 재생성 시 바뀔 수 있다. PostgreSQL 내부 주소 `10.20.0.45`는 Terraform에 고정되어 있다.
- PostgreSQL 자동 백업과 HA는 현재 구성하지 않았다.

## 운영 접속

```bash
ssh -i ~/.ssh/squarek8s ubuntu@$(cd terraform && terraform output -raw bastion_public_ip)
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```
