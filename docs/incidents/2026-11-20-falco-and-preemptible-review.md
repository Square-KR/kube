# Falco 도입과 preemptible 노드 자동 확장 검토

| 항목 | 내용 |
|---|---|
| 일시 | 2026-11-20 KST (preemptible 생성 시험 21:21 ~ 21:23) |
| 유형 | 작업 |
| 대상 | `squarek8s` 클러스터 워커, OCI `ap-seoul-1` A1 용량 |
| 상태 | 완료 |

## 요약

Falco 도입을 검토했고 보류했다. 이어서 preemptible(OCI의 spot) A1 노드 풀과 Cluster Autoscaler로 노드를 자동으로 늘리는 구성을 검토했다. A1 가격을 조회하고 preemptible A1 인스턴스를 실제로 만들었다 지워 생성 가능 여부를 확인했다. 도입 여부는 정하지 않았다.

## 영향

없음. 클러스터와 서비스에는 변경이 없었다. 시험 인스턴스는 약 1분 동안만 실행됐다.

## 타임라인

| 시각 (KST) | 내용 |
|---|---|
| 21:17 | OCI 공개 가격표 API에서 A1·Block Volume 단가 조회 |
| 21:17 ~ 21:21 | Compute 용량 리포트로 A1 1·2·4 OCPU 사양 조회. 모두 `AVAILABLE` |
| 21:21:08 | preemptible A1 시험 인스턴스 `squarek8s-preemptible-test` 생성 요청 |
| 21:21:41 | `RUNNING`, `FAULT-DOMAIN-3` |
| 21:22:44 | 인스턴스와 부트 볼륨 `TERMINATED` |

## 배경과 원인

- 클러스터 런타임 보안을 보강하는 방법으로 Falco를 검토했다.
- 11-19에 워커 CPU가 포화돼 kubelet이 응답하지 않은 일이 있었다([기록](2026-11-19-gitops-drift-and-node-cpu.md)). 이와 관련해 노드가 포화되면 자동으로 노드를 늘릴 수 있는지 확인했다.

## 조치

저장소 밖에서 한 작업:

- OCI CLI(`--profile k8s-tf`)로 `oci compute compute-capacity-report create`를 실행했다. 대상은 `VM.Standard.A1.Flex` 1 OCPU / 8 GB, 2 OCPU / 16 GB, 4 OCPU / 32 GB였다.
- preemptible 인스턴스를 1대 만들었다.
  - 사양은 `VM.Standard.A1.Flex` 1 OCPU / 8 GB, 이미지는 `Oracle-Linux-9.8-aarch64-2026.10.30-0`이다.
  - worker subnet `10.20.1.0/24`에 공인 IP 없이 만들었다.
  - `preemptionAction`은 `TERMINATE`, `preserveBootVolume: false`로 했다.
- `RUNNING`을 확인한 뒤 부트 볼륨까지 지우도록 종료했다.

## 검증

### Falco

- 워커 커널 `6.12.0-207.111.5.6.el9uek.aarch64`는 `modern_ebpf` 드라이버 요건(5.8 이상, BTF)을 만족한다. 확인한 최신 Helm chart는 `falcosecurity/falco` 9.2.2(Falco 0.45.2)이고 기본 requests는 CPU `100m`, 메모리 `512Mi`다.
- 노드 CPU requests는 할당 가능량 대비 76%, 55%였다. 클러스터 파드 36개 중 18개가 BestEffort였다.
- `dev`, `prod` 네임스페이스는 PSA `restricted`를 enforce하고, 공통 chart는 `runAsNonRoot`와 `readOnlyRootFilesystem`을 쓴다.

### preemptible과 Cluster Autoscaler

Oracle 문서에서 확인한 내용:

- OKE managed node pool은 preemptible 용량을 쓸 수 있고, `VM.Standard.A1.Flex`가 지원 shape 목록에 있다.
- 회수 2분 전에 이벤트가 온다. OKE는 노드를 cordon·drain한 뒤 종료하고, 대체 preemptible 노드를 만들려고 시도한다.
- 노드에는 `oci.oraclecloud.com/oke-is-preemptible` 라벨과 taint가 붙는다.
- Oracle은 preemptible을 기본 node pool로 쓰지 말라고 권한다.
- Cluster Autoscaler는 managed node pool에서 동작하고 0대까지 줄일 수 있다. Oracle은 Autoscaler가 관리하지 않는 node pool을 하나 두라고 권한다.
- Basic 클러스터에서 Autoscaler가 쓸 수 있는 OCI 인증은 instance principal과 API 키다. workload identity는 Enhanced 클러스터 전용이다.
- 회수 빈도나 평균 수명은 Oracle 문서에도 사용 후기(Pipefy 엔지니어링 블로그 등)에도 수치가 없었다.

클러스터에서 확인한 내용:

- metrics-server가 없고(`v1beta1.metrics.k8s.io` 없음) HPA도 없다. 서비스는 `replicas: 1`로 고정이다.
- 공통 chart에는 tolerations, nodeSelector, affinity 설정이 없다.
- 위 상태에서는 CPU가 포화돼도 Pending 파드가 생기지 않으므로 Cluster Autoscaler가 노드를 늘리지 않는다.

### A1 가격

OCI 공개 가격표 API 조회 결과다. 리전 구분이 없다.

| SKU | 항목 | 단가 |
|---|---|---|
| B93297 | A1 OCPU / 시간 | $0.01 (₩14.45) |
| B93298 | A1 메모리 GB / 시간 | $0.0015 (₩2.17) |
| B91961 | Block Volume 저장 GB / 월 | $0.0255 (₩36.86) |
| B91962 | Block Volume VPU / GB / 월 | $0.0017 (₩2.46) |

- preemptible SKU는 따로 없다. 문서상 on-demand보다 50% 저렴하고, 1분 안에 회수되면 그 시간은 과금하지 않는다.
- 1 OCPU / 8 GB 노드의 컴퓨트 비용:

  | | 시간당 | 730시간 |
  |---|---|---|
  | on-demand | $0.022 (₩31.8) | 약 $16.1 (₩23,200) |
  | preemptible | $0.011 (₩15.9) | 약 $8.0 (₩11,600) |

- 부트 볼륨 50 GB(Balanced 10 VPU)는 월 약 $2.1(₩3,100)이다.
- A1 무료 구간은 출처마다 달랐다.
  - 가격표 API: 월 3,000 OCPU시간 / 18,000 GB시간
  - Always Free 문서: 월 1,500 OCPU시간 / 9,000 GB시간

  실제로 어느 쪽이 적용되는지는 확인하지 않았다.

### 생성 시험

- 용량 리포트는 세 사양 모두 `AVAILABLE`이었다. 단, 이 리포트는 preemptible 용량을 따로 보여 주지 않는다.
- preemptible 인스턴스는 요청 후 33초 만에 `RUNNING`이 됐다. `Out of host capacity` 오류는 없었다.
- 종료 후 인스턴스와 부트 볼륨 `squarek8s-preemptible-test (Boot Volume)` 모두 `TERMINATED` 상태다.

## 결정 사항

- Falco 도입은 보류한다.
- preemptible 노드 풀과 Cluster Autoscaler는 검토만 했고 도입 여부는 정하지 않았다. 자동 확장이 동작하려면 시스템 파드 resource requests를 먼저 정리해야 한다. 이 작업은 이미 [backlog](../backlog.md)에 있다.
