# PROJECTS (MICROSERVICES)

## OVERVIEW

ApplicationSet-based multi-environment microservice deployments.

## STRUCTURE

```
projects/
├── _application.yaml           # App-of-Apps (sync-wave: 4)
├── accounts-backend/           # User service (Spring Boot)
│   ├── applicationset.yaml
│   ├── dev/  └── prod/
└── service-gateway/            # API gateway
    ├── applicationset.yaml
    ├── dev/  └── prod/
```

## WHERE TO LOOK

| Task | File | Notes |
|------|------|-------|
| Add new service | Copy existing dir | Update applicationset.yaml name/labels |
| Change image version | `{env}/values.yaml` | `image.version: <commit-sha>` |
| Add environment var | `{env}/values.yaml` | Under `env:` array |
| Configure secrets | `{env}/external-secret.yaml` | Match SSM path pattern |
| Add HTTP route | `{env}/httproute.yaml` | Attach to Gateway in `infra` ns |

## ADDING NEW SERVICE

1. Create `projects/{name}/applicationset.yaml`:
   - Generator: `list.elements: [{env: dev}, {env: prod}]`
   - Sources: repo ref + charts/app + env directory

2. Create `projects/{name}/{dev,prod}/`:
   - `values.yaml` (image, port, resources, secrets)
   - `external-secret.yaml` (AWS SSM → K8s secret)
   - `pull-secret.yaml` (ghcr.io auth)
   - `httproute.yaml` (optional, for external access)

3. Configure SSM:
   - SSM Parameter Store에 `/{env}/{service}/{VAR_NAME}` 경로로 파라미터 생성
   - ExternalSecret regexp: `^/{env}/{service}/`
   - rewrite로 경로 prefix strip: `^/{env}/{service}/(.*)` → `$1`

## CONVENTIONS

- **Namespace = environment**: `dev` namespace for dev, `prod` for prod
- **Service name = directory name**: `service-gateway/` → service name `service-gateway`
- **Image source**: `ghcr.io/square-kr/{service}:{commit-sha}`
- **Secrets**: One ExternalSecret per service per env
- **Pull secrets**: Each env needs `ghcr-pull-secret`

## ANTI-PATTERNS

- **No direct Deployments**: Always use Argo Rollout via `charts/app`
- **No cross-env references**: Each env is isolated
- **No hardcoded hostnames**: Use HTTPRoute attached to shared Gateway
