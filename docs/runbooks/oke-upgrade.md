# OKE 업그레이드

마지막 검증: 2026-11-19, 제어 플레인 `v1.36.4 → v1.37.1`, Envoy 프록시 2개 구성에서 워커 2대 교체. 3번의 버전·이미지 동시 변경을 여러 minor에 걸쳐 반복하는 경우는 미검증.

## 목적과 범위

OKE Basic Cluster의 제어 플레인과 워커 노드를 새 Kubernetes 버전으로 올린다. Bastion, PostgreSQL, 네트워크는 다루지 않는다.

## 사전 조건

- 기존 OCI Object Storage backend로 `terraform init -backend-config=backend.hcl`을 마친 상태
- 모든 ArgoCD 앱이 `Synced/Healthy`이고 두 워커의 루트 파일시스템 사용률이 70% 미만인 상태. 2026-10-09에는 디스크가 85%를 넘어 업그레이드 중 DiskPressure로 Pod 퇴거가 반복됐다.
- 배포 중인 모든 이미지에 `linux/arm64` manifest가 있는 상태
- `system/`, `observability/`, `bootstrap/` 컴포넌트가 목표 버전을 지원 범위에 두는 상태. 각 프로젝트의 호환성 표를 확인하고, 모자라면 업그레이드 전에 올린다. 2026-11-19에는 Envoy Gateway, External Secrets, cert-manager, Argo CD를 먼저 올렸다.
- 로컬 `kubectl`이 목표 버전과 minor 하나 이내인 상태

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

### 3. 제어 플레인 업그레이드와 워커 이미지 변경

제어 플레인은 minor 버전을 하나씩 올린다. `terraform/main.tf`의 `kubernetes_version`을 다음 minor의 지원 버전으로, `oke_image_name`을 같은 버전의 이미지로 함께 바꾸고 plan을 저장한다. OKE 이미지를 쓰는 node pool은 이미지가 버전을 정하므로, 버전만 바꾸면 node pool 변경이 `409-Conflict, Cannot update Kubernetes version which has already been set by OKE worker node image`로 실패한다. 이때 제어 플레인 업그레이드는 이미 끝난 상태이므로 이미지를 바꿔 다시 plan·apply하면 된다.

```bash
terraform plan -out=upgrade.tfplan
```

plan에 `oci_containerengine_cluster.main`과 `oci_containerengine_node_pool.workers`의 in-place 변경만 있는지 확인한 뒤 apply한다. 교체(`-/+`)가 있으면 멈춘다. 목표 버전까지 반복한다. 2026-11-19에는 제어 플레인 변경에 8분이 걸렸고 서비스 중단은 없었다.

```bash
terraform apply upgrade.tfplan
```

node pool 설정 변경은 새로 만드는 노드에만 적용되고 기존 노드는 그대로 남는다.

### 4. 워커 교체

**위험:** 노드를 비우는 동안 그 노드의 파드가 재시작된다. 새 노드는 이미지 캐시가 비어 있어, 큰 이미지(Argo CD 650 MB, notification-backend 830 MB)는 다시 뜨기까지 3분쯤 걸린다. 2026-11-19에는 replicas 1인 honami가 약 1분, argocd-server가 약 3분 503을 반환했다.

1. `node_config_details.size`를 3으로 올려 apply하고, 새 노드가 `Ready`이고 그 노드의 DaemonSet 파드가 모두 Running이 될 때까지 기다린다.
2. 기존 노드를 하나씩 비운다. Envoy 프록시는 PDB `minAvailable: 1`이라 하나씩만 내려가고, 노드별 분산 때문에 프록시가 없는 노드로 옮겨간다.

   ```bash
   kubectl cordon <node>
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m
   ```

3. 비운 노드를 node pool에서 삭제한다. 마지막 기존 노드가 아니면 크기를 유지해 새 노드가 대신 만들어지게 하고, 새 노드가 `Ready`가 되면 다음 노드로 넘어간다. 마지막 기존 노드는 크기를 줄이면서 삭제한다. 나중에 `size`만 줄이면 OCI가 지울 노드를 고르므로 새 노드가 지워질 수 있다.

   ```bash
   NP=$(terraform state show -no-color oci_containerengine_node_pool.workers | awk -F'"' '/^    id /{print $2}')
   NID=$(oci ce node-pool get --profile k8s-tf --node-pool-id "$NP" \
     --query "data.nodes[?\"private-ip\"=='<node-ip>'].id | [0]" --raw-output)
   oci ce node-pool delete-node --profile k8s-tf --node-pool-id "$NP" --node-id "$NID" \
     --is-decrement-size false --force   # 마지막 기존 노드는 true
   ```

4. `main.tf`의 `size`를 2로 되돌리고 plan이 "No changes"인지 확인한다.

2026-10-09에는 첫 drain이 15분 eviction timeout으로 실패했다. 강제로 종료하지 않고 새 워커와 운영 파드가 정상임을 확인한 뒤 기존 노드를 재부팅해 진행했다.

drain 중 External Secrets webhook이 옮겨가는 동안 `external-secrets` 앱이 Server-Side Diff의 webhook 호출 실패로 `Unknown`이 될 수 있다. webhook이 Ready가 된 뒤 hard refresh하면 돌아온다.

### 5. 문서 갱신

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

제어 플레인은 이전 버전으로 되돌릴 수 없다. 워커는 node pool의 `kubernetes_version`과 `oke_image_name`을 이전 값으로 돌리고 4번 절차로 노드를 다시 교체한다. node pool은 제어 플레인과 같은 `local.kubernetes_version`을 쓰므로, 롤백하려면 node pool 버전을 따로 지정해야 한다(미검증). state가 어긋나면 2번에서 백업한 state와 비교한다.

## 관련 문서

- [2026-10-09 OKE 업그레이드 기록](../incidents/2026-10-09-oke-upgrade.md)
- [OKE 버전 및 업그레이드 순서](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengupgradeoverview.htm)
- [Basic Cluster 워커 교체 절차](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengupgradingk8sworkernode_topic-Performing_an_InPlace_Worker_Node_Upgrade_by_Updating_an_Existing_Node_Pool.htm)
