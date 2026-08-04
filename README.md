# Square-KR Kubernetes

OCI OKE와 ArgoCD App-of-Apps로 운영하는 Kubernetes GitOps 저장소다.

## 인프라 생성

OCI CLI의 `k8s-tf` API 키 프로필과 Object Storage 상태 버킷을 준비한 뒤 실행한다.

```bash
cd terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan -out=squarek8s.tfplan
terraform apply squarek8s.tfplan
```

`terraform output -raw kubeconfig_command`가 출력하는 명령으로 kubeconfig를 만든다.

## 클러스터 부트스트랩

```bash
export KUBECONFIG=~/.kube/oke-squarek8s
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
./bootstrap.sh
```

OKE가 Flannel CNI를 제공하며, 외부 트래픽은 Envoy Gateway와 OCI Flexible Load Balancer를 사용한다.
로드밸런서가 준비되면 Cloudflare의 `sqr.kr`, `*.sqr.kr` proxied A 레코드를 새 공인 IP로 변경한다.
