# OKE 업그레이드

마지막 검증: 2026-10-09, 제어 플레인 `v1.33.10 → v1.36.4`, 워커 2대 교체. Envoy 프록시 2개 구성에서의 워커 교체는 미검증.

## 목적과 범위

OKE Basic Cluster의 제어 플레인과 워커 노드를 새 Kubernetes 버전으로 올린다. Bastion, PostgreSQL, 네트워크는 다루지 않는다.

## 사전 조건

- 기존 OCI Object Storage backend로 `terraform init -backend-config=backend.hcl`을 마친 상태
- 모든 ArgoCD 앱이 `Synced/Healthy`이고 두 워커의 루트 파일시스템 사용률이 70% 미만인 상태. 2026-10-09에는 디스크가 85%를 넘어 업그레이드 중 DiskPressure로 Pod 퇴거가 반복됐다.
- 배포 중인 모든 이미지에 `linux/arm64` manifest가 있는 상태

## 절차

### 1. 목표 버전과 노드 이미지 확인

```bash
oci ce cluster-options get --cluster-option-id all --profile k8s-tf \
  --query 'data."kubernetes-versions"'
oci ce node-pool-options get --node-pool-option-id all --profile k8s-tf \
  --query 'data.sources[?contains("source-name", `aarch64`)]."source-name"'
```

목표 버전과, 그 버전이 이름에 들어간 `Oracle-Linux-*-aarch64-*-OKE-*` 이미지를 고른다.

### 2. state 백업

```bash
cd terraform
terraform state pull > <저장소 밖 비공개 경로>/squarek8s-$(date +%Y%m%d).tfstate
```

### 3. 제어 플레인 업그레이드

제어 플레인은 minor 버전을 하나씩 올린다. `terraform/main.tf`의 `kubernetes_version`을 다음 minor의 지원 버전으로 바꾸고 plan을 저장한다.

```bash
terraform plan -out=upgrade.tfplan
```

plan에 `oci_containerengine_cluster.main`과 `oci_containerengine_node_pool.workers`의 in-place 변경만 있는지 확인한 뒤 apply한다. 교체(`-/+`)가 있으면 멈춘다. 목표 버전까지 반복한다.

```bash
terraform apply upgrade.tfplan
```

### 4. 워커 이미지 변경

`oke_image_name`을 1번에서 고른 이미지로 바꾸고 3번과 같은 방식으로 plan을 확인하고 apply한다. node pool 설정 변경은 새로 만드는 노드에만 적용되고 기존 노드는 그대로 남는다.

### 5. 워커 교체

**위험:** 노드를 비우는 동안 그 노드의 파드가 재시작된다. honami는 replicas 1이라 짧게 끊길 수 있다.

1. `node_config_details.size`를 3으로 올려 apply하고 새 노드가 `Ready`가 될 때까지 기다린다.
2. 기존 노드를 하나씩 비운다. Envoy 프록시는 PDB `minAvailable: 1`이라 하나씩만 내려간다.

   ```bash
   kubectl cordon <node>
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m
   ```

3. 비운 노드를 OCI 콘솔이나 `oci ce node-pool delete-node`로 node pool에서 삭제한다. 새 노드가 대신 만들어지면 `Ready`를 확인하고 다음 노드로 넘어간다.
4. 모든 기존 노드를 바꾼 뒤 `size`를 2로 되돌리고 apply한다. 노드 수와 plan "No changes"를 확인한다.

2026-10-09에는 첫 drain이 15분 eviction timeout으로 실패했다. 강제로 종료하지 않고 새 워커와 운영 파드가 정상임을 확인한 뒤 기존 노드를 재부팅해 진행했다.

### 6. 문서 갱신

README "현재 구성"의 OKE 버전을 고치고, 작업 내용을 [기록 템플릿](../templates/record.md)으로 남긴다.

## 검증

```bash
kubectl get nodes -o wide
kubectl -n argocd get applications
kubectl -n envoy-gateway-system get pods -o wide -l app.kubernetes.io/component=proxy
curl -s -o /dev/null -w '%{http_code}\n' https://argocd.sqr.kr
```

- 모든 노드가 목표 버전으로 `Ready`이고 DiskPressure가 없다.
- 모든 ArgoCD 앱이 `Synced/Healthy`다.
- Envoy 프록시가 노드마다 하나씩 있고 OCI LB backend가 모두 OK다.
- `argocd.sqr.kr`과 `mllm.kr`이 정상 응답한다.

## 롤백

제어 플레인은 이전 버전으로 되돌릴 수 없다. 워커는 `oke_image_name`과 node pool `kubernetes_version`을 이전 값으로 돌리고 5번 절차로 노드를 다시 교체한다. state가 어긋나면 2번에서 백업한 state와 비교한다.

## 관련 문서

- [2026-10-09 OKE 업그레이드 기록](../incidents/2026-10-09-oke-upgrade.md)
- [OKE 버전 및 업그레이드 순서](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengupgradeoverview.htm)
- [Basic Cluster 워커 교체 절차](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengupgradingk8sworkernode_topic-Performing_an_InPlace_Worker_Node_Upgrade_by_Updating_an_Existing_Node_Pool.htm)
