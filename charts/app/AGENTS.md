# GENERIC APP HELM CHART

## OVERVIEW

`charts/app`은 서비스 워크로드 공통 Helm chart다. Argo Rollout blue-green 배포와 ClusterIP Service만 만든다. 서비스별 차이는 `projects/{service}/{env}/values.yaml`에서 주입하며 기본값은 `values.yaml`에 있다.

## FILES

| 파일 | 역할 |
|---|---|
| `values.yaml` | 기본값 |
| `templates/_helpers.tpl` | 이름·라벨 helper |
| `templates/rollout.yaml` | 애플리케이션 Rollout |
| `templates/service.yaml` | blue-green 활성 Service |

## BEHAVIOR

코드만 봐서는 드러나지 않는 동작이다.

- Rollout과 Service 이름은 Helm release name이다. ApplicationSet의 `releaseName`을 서비스 디렉터리 이름과 같게 둔다.
- 컨테이너 이름은 항상 `app`, Service 포트는 항상 `80`이고 `targetPort`는 `port`다.
- `LISTEN_PORT`, `HOST_IP`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://$(HOST_IP):4317`을 항상 넣는다. OTLP는 같은 노드의 Datadog Agent로 간다.
- `reloader.stakater.com/auto: "true"`가 항상 붙는다. `secrets`로 참조한 Secret이 바뀌면 Reloader가 Pod template에 `reloader.stakater.com/last-reloaded-from`을 써서 blue-green 재배포가 일어난다.
- `restricted` Pod Security를 통과하도록 non-root, `RuntimeDefault` seccomp, 읽기 전용 루트 파일시스템, 모든 capability drop으로 실행한다. 쓰기가 필요하면 메모리 기반 `/tmp`(64Mi)를 쓴다.
- ServiceAccount 토큰은 마운트하지 않는다.
- `resources.cpu`는 requests에만, `resources.memory`는 requests와 limits에 같이 들어간다. CPU limit은 두지 않는다.
- namespace는 chart에서 지정하지 않고 ArgoCD destination을 따른다.

## WHEN TO EDIT

모든 서비스에 공통으로 적용해야 하는 배포 동작이나 값 스키마를 바꿀 때만 고친다. 먼저 서비스 `values.yaml` 오버라이드로 해결되는지 확인하고, 변경이 모든 서비스와 환경에 동시에 적용되어도 되는지 확인한다. 고친 뒤에는 `scripts/validate-manifests.sh`로 모든 서비스의 렌더링을 확인한다.

## DO NOT

- 특정 서비스 요구 때문에 공통 템플릿에 분기를 넣지 않는다.
- chart 안에 환경별 값이나 서비스명을 하드코딩하지 않는다.
- `Deployment` 템플릿을 추가해 Rollout을 우회하지 않는다.
- selector 라벨(`app.selectorLabels`)을 바꾸지 않는다. 기존 ReplicaSet, Service 셀렉터와 어긋나 모든 서비스를 다시 배포해야 한다.
