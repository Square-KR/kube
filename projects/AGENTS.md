# PROJECTS

## OVERVIEW

`projects/`는 서비스 배포 정의다. 서비스마다 `ApplicationSet` 하나가 환경별 Application을 만들고, 워크로드는 공통 chart `charts/app`으로 배포한다.

## SERVICES

| 서비스 | 환경 | 네임스페이스 | 외부 주소 | 비고 |
|---|---|---|---|---|
| `notification-backend` | `dev` | `dev` | 없음 (클러스터 내부 `notification-backend.dev.svc.cluster.local`) | |
| `honami` | `prod` | `prod` | `mllm.kr` | replicas 1 고정 |

## FILES

| 파일 | 역할 |
|---|---|
| `_application.yaml` | `projects/` 아래 `application.yaml`, `applicationset.yaml` 수집 |
| `{service}/applicationset.yaml` | 환경별 ArgoCD Application 생성 |
| `{service}/{env}/values.yaml` | 공통 chart 오버라이드. 이미지 배포 워크플로가 `image.version`을 고친다 |
| `{service}/{env}/external-secret.yaml` | SSM `/{env}/{service}/`를 서비스 Secret으로 매핑 |
| `{service}/{env}/httproute.yaml` | 외부 노출이 필요할 때만 |

## CONVENTIONS

- ApplicationSet은 source 세 개를 묶는다: repo ref, `charts/app` Helm source(`valueFiles: $repo/projects/{service}/{env}/values.yaml`), 환경 디렉터리(`directory.exclude: values.yaml`). Kustomize는 쓰지 않는다.
- `metadata.name`, Helm `releaseName`, 서비스 디렉터리 이름을 같게 둔다. namespace는 환경 이름과 같다.
- ApplicationSet에는 Service의 `rollouts-pod-template-hash` 셀렉터와 Rollout의 `reloader.stakater.com/last-reloaded-from` 어노테이션에 대한 `ignoreDifferences`, `RespectIgnoreDifferences=true`를 둔다. 빠지면 blue-green 전환과 시크릿 변경 후 자동 재시작이 selfHeal로 되돌려진다.
- `managedNamespaceMetadata`에는 `square-kr.io/ghcr-pull-secret: "true"`와 Pod Security `enforce`·`audit`·`warn: restricted`를 둔다. `*-version` 라벨은 두지 않는다.
- ExternalSecret은 `dataFrom.find.name.regexp: "^/{env}/{service}/"`로 찾고 `rewrite`로 prefix를 지워 키 이름만 남긴다. SSM 값을 바꾸면 최대 1시간 안에 Secret이 갱신되고 Reloader가 재배포한다.
- HTTPRoute는 `infra/http` Gateway의 listener에 붙이고 `backendRefs`에 `group: ""`, `kind: Service`, `weight: 1`을 명시한다. `weight`를 뺐을 때 ArgoCD drift가 생겨 `fdce5bf`에서 추가했다.
- 이미지는 `linux/arm64` manifest를 포함해야 한다. 서비스 저장소가 `deploy-image` `repository_dispatch`(`service`, `environment`, `version`)를 보내면 워크플로가 `image.version`을 커밋한다.
- GHCR 인증은 공용 `ghcr-pull-secret`을 `imagePullSecrets`로 참조한다.

## 새 서비스 추가 체크리스트

1. SSM `/{env}/{service}/`에 시크릿을 넣는다. DB가 필요하면 [PostgreSQL 런북](../docs/runbooks/postgresql.md#서비스-db-추가)의 서비스 DB 추가 절차를 먼저 한다.
2. 기존 서비스의 `applicationset.yaml`을 복사해 이름, `releaseName`, 경로, component 라벨, generator 환경을 바꾼다.
3. `{env}/values.yaml`, `{env}/external-secret.yaml`, 필요하면 `{env}/httproute.yaml`을 만든다. 새 도메인이면 Gateway listener와 Cloudflare 레코드도 확인한다.
4. `scripts/validate-manifests.sh`를 실행한다.
5. 위 SERVICES 표를 고친다.

환경을 추가할 때는 generator에 환경을 넣고 같은 이름의 디렉터리를 함께 만든다.

## DO NOT

- 서비스별 pull secret을 만들지 않는다.
- 서비스마다 배포 템플릿을 복사하지 않는다.
- `values.yaml`에 시크릿 값을 넣지 않는다.
- generator에 없는 환경 디렉터리만 추가하지 않는다.
- `kustomization.yaml`을 추가하지 않는다.
