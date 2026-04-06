# GENERIC APP HELM CHART

## OVERVIEW

`charts/app`은 서비스 워크로드 공통 Helm chart다. 현재 chart는 Argo Rollout 기반 blue-green 배포, ClusterIP Service, 선택적 HPA/PDB만 제공하며, 개별 서비스 차이는 환경별 `values.yaml`에서 주입한다.

## FILES

| 파일 | 역할 |
|------|------|
| `Chart.yaml` | chart 메타데이터 |
| `values.yaml` | 기본값 정의 |
| `templates/_helpers.tpl` | 이름/라벨 helper |
| `templates/rollout.yaml` | 애플리케이션 Rollout |
| `templates/service.yaml` | 활성 Service |
| `templates/hpa.yaml` | 선택적 CPU 기반 HPA |
| `templates/pdb.yaml` | 선택적 PDB |

## DEFAULT VALUES

```yaml
replicas: 1

port: 3000

healthCheck:
  port: ""
  liveness: /healthz/liveness
  readiness: /healthz/readiness

image:
  name: ""
  version: latest

resources:
  cpu: "100m"
  memory: "128Mi"

env: []
secrets: []
imagePullSecrets: []

hpa:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 50

pdb:
  enabled: false
  minAvailable: "50%"
```

## TEMPLATE BEHAVIOR

### `rollout.yaml`

- 리소스 타입은 `argoproj.io/v1alpha1` `Rollout`
- `hpa.enabled: false`일 때만 `spec.replicas`를 렌더링한다.
- 컨테이너 이름은 항상 `app`
- 이미지 경로는 `"{{ .Values.image.name }}:{{ .Values.image.version }}"`
- 기본 env:
  - `LISTEN_PORT`
  - `HOST_IP` (`status.hostIP` fieldRef)
  - `OTEL_EXPORTER_OTLP_ENDPOINT=http://$(HOST_IP):4317`
- `env` 배열은 그대로 추가한다.
- `secrets` 배열이 있으면 `envFrom.secretRef`로 주입한다.
- `reloader.stakater.com/auto: "true"` annotation이 항상 들어간다.
- `revisionHistoryLimit: 2`
- `topologySpreadConstraints`를 기본으로 걸어 노드 분산을 시도한다.
- 전략은 `blueGreen.activeService=<fullname>`

### `service.yaml`

- `ClusterIP` Service를 생성한다.
- 서비스 포트는 항상 `80`
- `targetPort`는 `.Values.port`

### `hpa.yaml`

- `hpa.enabled: true`일 때만 생성한다.
- 대상은 `Rollout` 리소스다.
- 현재 메트릭은 CPU utilization 하나만 사용한다.

### `pdb.yaml`

- `pdb.enabled: true`일 때만 생성한다.
- `minAvailable`만 사용한다.

## CURRENT CONVENTIONS

- 서비스명은 보통 Helm release name과 동일하게 둔다.
- namespace는 chart 내부에서 지정하지 않고 ArgoCD destination namespace를 따른다.
- GHCR 인증은 서비스별 시크릿을 만들지 않고 공용 `ghcr-pull-secret`을 `imagePullSecrets`로 참조한다.
- 리소스 요청/제한은 현재 구조상 `cpu=requests`, `memory=limits`만 기본 템플릿에서 직접 다룬다.
- readiness/liveness 경로가 기본값과 다르면 서비스별 `values.yaml`에서 반드시 덮어쓴다.

## WHEN TO EDIT THIS CHART

- 모든 서비스에 공통으로 적용돼야 하는 배포 동작을 바꿀 때
- 공통 값 스키마를 추가할 때
- 새로운 공통 Kubernetes 리소스를 템플릿으로 제공할 때

먼저 확인할 것:
- 서비스별 차이만으로 해결 가능한가
- 기존 `values.yaml` 오버라이드로 충분한가
- chart 변경이 현재 모든 서비스와 환경에 동시에 영향을 줘도 되는가

## DO NOT

- 특정 서비스 요구사항 때문에 공통 템플릿을 바로 분기하지 말 것
- chart 안에 환경별 값이나 서비스명을 하드코딩하지 말 것
- `Deployment` 템플릿을 추가해 Rollout 경로를 우회하지 말 것
