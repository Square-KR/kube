# OKE Kubernetes 업그레이드 기록

대상: 서울 리전 `squarek8s` Basic Cluster. 목표 버전: `v1.36.4`.

## 진행 상황

- 제어 플레인: `v1.33.10 → v1.34.10 → v1.35.2 → v1.36.4` 완료.
- 워커: `v1.36.4` 임시 워커를 추가한 뒤 기존 `v1.33.10` 2대를 순차 교체하고 2대로 복원했다. 2026-10-29 기준 `10.20.1.108`, `10.20.1.58` 모두 `v1.36.4` Ready다.
- 목표 ARM 이미지: `Oracle-Linux-9.8-aarch64-2026.08.14-0-OKE-1.36.4-1820`.
- 기존 OCI Object Storage state를 확인하고 로컬 비공개 임시 디렉터리에 작업 전 state를 백업했다.
- 단계별 저장된 Terraform plan에서 해당 OKE 리소스의 in-place 변경만 허용했다.

## 작업 중 확인한 기존 문제

- 두 워커의 루트 디스크가 각각 85%, 89% 사용 중이었고 DiskPressure와 반복적인 Pod 퇴거가 발생했다.
- 각 노드의 닫힌 messages 로그 `20260913`, `20260920`, `20260927`, `20261004`를 낮은 CPU/I/O 우선순위로 압축하고 `gzip -t`로 검증했다. 현재 로그와 보안 로그 설정은 변경하지 않았다.
- 정리 후 루트 사용률은 각각 39%, 49%였고 두 노드의 DiskPressure가 해제됐다. 임시 진단/압축 Pod는 삭제했다.
- 작업 중 Cloudflare TLS 오류 HTTP 525가 관측됐다. Envoy의 인증서와 리스너가 로드된 것을 확인했고 운영 readiness와 ArgoCD가 HTTP 200으로 복구된 것을 확인했다.
- 첫 워커 drain은 15분 Pod eviction timeout으로 실패했고 강제 종료하지 않았다. kubelet 로그에서 대량의 과거 Pod 삭제 이벤트 처리가 관측됐다. 새 워커 2대의 Ready, 운영 백엔드의 정상 실행 및 PVC 부재를 확인한 뒤 기존 워커 `10.20.1.55`를 정상 재부팅하여 동기화 복구를 진행했다.
- 개발 알림 서비스는 작업 전부터 `ghcr.io/square-kr/notification-backend:990fbec8`의 ARM manifest 누락으로 실행되지 않았다. 커밋 `9141f64`에서 ARM 이미지가 있는 `66f76082`로 되돌려 복구했다. 이후 배포 이미지는 `linux/arm64`를 포함해야 한다.
- 로그 보존 정책의 영구 개선은 [DiskPressure 기록](2026-09-10-disk-pressure.md)의 계획에 남아 있으며 아직 적용하지 않았다.
- 업그레이드 후 `dev`, `prod` 네임스페이스의 Pod Security 버전 라벨은 `v1.33`으로 남았다. `dev`는 ApplicationSet에서 `v1.36`으로 갱신했고 `prod`는 관리하는 Application이 없어 수동 정리 대상이다.

## 근거

- [OKE 버전 및 업그레이드 순서](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengupgradeoverview.htm): 제어 플레인은 minor 버전별로 순차 업그레이드하며 워커는 중간 버전을 건너뛸 수 있다.
- [Basic Cluster 워커 교체 절차](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengupgradingk8sworkernode_topic-Performing_an_InPlace_Worker_Node_Upgrade_by_Updating_an_Existing_Node_Pool.htm).
