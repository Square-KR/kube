# PROJECTS

## OVERVIEW

`projects/`는 서비스 배포 정의 영역이다. 각 서비스는 `ApplicationSet`으로 관리하며, 공통 배포 로직은 `charts/app`을 재사용하고 서비스별 환경 값과 부가 매니페스트를 함께 묶는다.

## CURRENT STRUCTURE

```text
projects/
├── _application.yaml
└── notification-backend/
    ├── applicationset.yaml
    └── dev/
        ├── external-secret.yaml
        └── values.yaml
```

현재 워킹 트리 기준으로 서비스 정의는 `notification-backend` 하나이며, 환경 디렉터리는 `dev`만 존재한다.

## FILE RESPONSIBILITIES

| 파일 | 역할 |
|------|------|
| `_application.yaml` | `projects/` 하위 `application.yaml`, `applicationset.yaml` 수집 |
| `{service}/applicationset.yaml` | 환경별 ArgoCD Application 생성 |
| `{service}/{env}/values.yaml` | 공통 Helm chart 오버라이드 |
| `{service}/{env}/external-secret.yaml` | SSM 경로를 서비스 secret으로 매핑 |

## CURRENT SERVICE PATTERN

### `notification-backend`

- Helm release name: `notification-backend`
- 배포 namespace: generator의 `env` 값 사용, 현재는 `dev`
- chart source: `charts/app`
- manifest source: `projects/notification-backend/{env}`
- 현재 image: `ghcr.io/square-kr/notification-backend`
- 현재 health check:
  - liveness: `/healthz`
  - readiness: `/readyz`

## HOW A SERVICE IS WIRED

`applicationset.yaml`은 보통 세 개의 source를 묶는다.

1. repo ref source
2. `charts/app` Helm source
3. 서비스 환경 디렉터리 source

현재 `notification-backend`는 generator에 `dev`만 선언되어 있으므로, prod를 추가하려면 ApplicationSet generator와 `prod/` 디렉터리를 같이 추가해야 한다.

## SECRETS CONVENTION

- 서비스 시크릿은 `/{env}/{service}/...` SSM 경로를 사용한다.
- `external-secret.yaml`은 `find.name.regexp`로 서비스 prefix를 찾는다.
- `rewrite.regexp`로 prefix를 제거해 Kubernetes secret key로 변환한다.
- 이미지 pull secret은 서비스 디렉터리에서 만들지 않고 공용 `ghcr-pull-secret`을 참조한다.

예시:

```text
/dev/notification-backend/FOO
-> ExternalSecret rewrite
-> secret key: FOO
```

## WHEN ADDING OR UPDATING A SERVICE

### 새 서비스 추가

필수 파일:
- `projects/{service}/applicationset.yaml`
- `projects/{service}/{env}/values.yaml`
- `projects/{service}/{env}/external-secret.yaml`

필요 시 추가:
- `httproute.yaml`
- ConfigMap, Secret, NetworkPolicy 등 서비스별 보조 리소스

체크 포인트:
- `metadata.name`, Helm `releaseName`, 디렉터리명이 일치하는가
- `destination.namespace`가 env와 맞는가
- `valueFiles` 경로가 실제 파일과 맞는가
- SSM 경로 prefix와 rewrite regexp가 서비스명과 맞는가

### 기존 서비스 수정

- 이미지 태그 변경: `{env}/values.yaml`
- 포트/프로브 변경: `{env}/values.yaml`
- 환경변수 추가: `{env}/values.yaml`의 `env`
- secret 매핑 추가: `{env}/external-secret.yaml`
- 외부 노출 추가: 서비스 env 디렉터리에 `httproute.yaml` 추가 후 Gateway에 attach

## CURRENT CONVENTIONS

- namespace는 환경명과 동일하게 쓴다.
- 서비스 워크로드는 직접 작성하지 않고 `charts/app`을 통해 Rollout으로 배포한다.
- 공통 GHCR 인증은 `system/external-secrets/ghcr-pull-secret.yaml`에서 관리한다.
- 환경별 매니페스트 디렉터리에는 `values.yaml`을 제외한 추가 리소스만 두고, `applicationset.yaml`에서 `directory.exclude: values.yaml`로 분리한다.

## DO NOT

- 서비스별 `pull-secret.yaml`을 다시 만들지 말 것
- 서비스마다 배포 템플릿을 복사해 중복 관리하지 말 것
- `values.yaml`에 시크릿 값을 직접 넣지 말 것
- generator에 없는 env 디렉터리를 추가만 하고 ApplicationSet을 안 바꾸는 상태로 두지 말 것
