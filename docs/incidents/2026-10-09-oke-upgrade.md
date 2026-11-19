# OKE Kubernetes 업그레이드

| 항목 | 내용 |
|---|---|
| 일시 | 2026-10-09 시작, 2026-10-29 워커 교체 완료 확인 |
| 유형 | 작업 |
| 대상 | 서울 리전 `squarek8s` Basic Cluster |
| 상태 | 완료 |

## 요약

제어 플레인을 `v1.33.10 → v1.34.10 → v1.35.2 → v1.36.4`로 올리고 워커 2대를 `v1.36.4` 노드로 교체했다. 작업 중 워커 디스크 포화로 DiskPressure가 났고 Cloudflare 525가 관측됐으며, 이미 ARM 이미지 누락으로 멈춰 있던 개발 알림 서비스를 복구했다. 반복 절차는 [OKE 업그레이드 런북](../runbooks/oke-upgrade.md)에 정리했다.

## 영향

- 두 워커의 루트 디스크가 85%, 89%라 DiskPressure와 반복적인 Pod 퇴거가 있었다.
- 작업 중 Cloudflare TLS 오류 HTTP 525가 관측됐다.
- 개발 알림 서비스는 작업 전부터 `ghcr.io/square-kr/notification-backend:990fbec8`의 ARM manifest 누락으로 실행되지 않고 있었다.

## 배경과 원인

목표 버전은 `v1.36.4`, ARM 노드 이미지는 `Oracle-Linux-9.8-aarch64-2026.08.14-0-OKE-1.36.4-1820`이다. OKE 제어 플레인은 minor 버전 단위로 순차 업그레이드해야 하고 워커는 중간 버전을 건너뛸 수 있다.

근거: [OKE 버전 및 업그레이드 순서](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengupgradeoverview.htm), [Basic Cluster 워커 교체 절차](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengupgradingk8sworkernode_topic-Performing_an_InPlace_Worker_Node_Upgrade_by_Updating_an_Existing_Node_Pool.htm).

## 조치

| 커밋 | 내용 |
|---|---|
| `9141f64` (2026-10-14) | 알림 서비스 이미지를 ARM manifest가 있는 `66f76082`로 되돌리고, GHCR 정리가 multi-arch child manifest를 지우지 않게 함 |
| `1709d0e` (2026-10-29) | `terraform/main.tf`의 OKE 버전·노드 이미지, dev ApplicationSet의 Pod Security 버전 라벨, 이 기록 |

저장소 밖에서 한 작업:

- 기존 OCI Object Storage state를 확인하고 작업 전 state를 로컬 비공개 임시 디렉터리에 백업했다.
- 단계마다 저장한 Terraform plan에서 OKE 리소스의 in-place 변경만 허용했다.
- `v1.36.4` 임시 워커를 추가한 뒤 기존 `v1.33.10` 워커 2대를 순차 교체하고 2대로 되돌렸다.
- 각 노드의 닫힌 messages 로그 `20260913`, `20260920`, `20260927`, `20261004`를 낮은 CPU/I/O 우선순위로 압축하고 `gzip -t`로 검증했다. 임시 진단·압축 Pod는 지웠다.
- 첫 워커 drain이 15분 Pod eviction timeout으로 실패했다. 강제 종료하지 않았고, kubelet이 대량의 과거 Pod 삭제 이벤트를 처리하는 것을 확인했다. 새 워커 2대의 Ready, 운영 백엔드의 정상 실행과 PVC 부재를 확인한 뒤 기존 워커 `10.20.1.55`를 정상 재부팅해 진행했다.
- 단일 Envoy 프록시를 보완하려고 임시 ReplicaSet `envoy-gateway-system/oke-upgrade-envoy-surge`를 만들었다. 이 ReplicaSet은 ArgoCD가 관리하지 않았다.

## 검증

- 디스크 정리 후 루트 사용률은 39%, 49%였고 DiskPressure가 풀렸다.
- Envoy 인증서와 리스너가 로드된 것을 확인했고, 운영 readiness와 ArgoCD가 HTTP 200으로 돌아왔다.
- 2026-10-29 기준 `10.20.1.108`, `10.20.1.58` 모두 `v1.36.4` Ready였다.

## 결정 사항

- 이후 배포 이미지는 `linux/arm64`를 포함해야 한다.

## 후속 작업

- messages 로그 보존 정책: 2026-10-29 `61c951e`로 완료([DiskPressure 기록](2026-09-10-disk-pressure.md)).
- `dev`, `prod`의 Pod Security 버전 라벨이 `v1.33`으로 남았다. `dev`는 작업 중 ApplicationSet에서 `v1.36`으로 갱신했고, `prod`는 2026-11-19 honami ApplicationSet이 관리하게 되었다. 같은 날 `2069bc7`로 버전 라벨을 없애 클러스터 버전을 따르게 했다.
- 임시 Envoy ReplicaSet: 2026-11-19 Envoy 프록시를 2개로 구성한 뒤 삭제했다([정리 기록](2026-11-19-repo-and-cluster-cleanup.md)).
