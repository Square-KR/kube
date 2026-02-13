# KUBERNETES GITOPS KNOWLEDGE BASE

**Generated:** 2025-02-01
**Commit:** 8403d2b
**Branch:** main

## OVERVIEW

ArgoCD-managed Kubernetes GitOps monorepo for Square-KR microservices. Cilium CNI, Argo Rollouts (blue-green), External-Secrets (AWS SSM Parameter Store).

## STRUCTURE

```
.
├── bootstrap/          # Cluster init: Cilium CNI + ArgoCD
├── system/             # Core: cert-manager, external-secrets, argo-rollouts, reloader
├── networking/         # Gateway API (Cilium) + HTTPRoutes
├── platform/           # Data layer: Valkey (Redis)
├── observability/      # Monitoring: Datadog agent
├── projects/           # Microservices: accounts-backend, service-gateway
├── charts/app/         # Generic Helm chart for all workloads
├── root.yaml           # ArgoCD App-of-Apps entry point
└── bootstrap.sh        # Cluster bootstrap script
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add new microservice | `projects/{name}/` | Copy existing, update applicationset.yaml |
| Modify Helm defaults | `charts/app/values.yaml` | Affects all services |
| Add system component | `system/{name}/` | Create application.yaml |
| Configure secrets | `system/external-secrets/` | AWS SSM ClusterSecretStore |
| Update gateway/routes | `networking/gateway/` | Gateway API resources |
| Configure monitoring | `observability/datadog-agent/` | Datadog agent settings |
| Bootstrap new cluster | `bootstrap.sh` | Requires AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY |

## SYNC WAVE ORDER

ArgoCD deploys in this sequence (annotations):

| Wave | Component | Purpose |
|------|-----------|---------|
| 0 | cert-manager | TLS certificates first |
| 1 | system | External-secrets, reloader, argo-rollouts |
| 2 | networking | Gateway, HTTP redirect |
| 3 | platform | Valkey cache |
| 4 | observability | Datadog agent (monitoring, APM, logs) |
| 5 | projects | Microservices last |

## CONVENTIONS

### ArgoCD Apps
- `_application.yaml` = App-of-Apps parent (picks up `**/{application,applicationset}.yaml`)
- `applicationset.yaml` = Multi-env deployments (dev/prod generators)
- `application.yaml` = Single deployment

### Environment Structure
```
projects/{service}/
├── applicationset.yaml    # ArgoCD ApplicationSet
├── dev/
│   ├── values.yaml        # Helm values (image, resources)
│   ├── external-secret.yaml
│   ├── pull-secret.yaml
│   └── httproute.yaml     # Gateway route
└── prod/
    └── (same structure)
```

### Secret Naming
- SSM Parameter Store 경로 기반: `/{env}/{service}/{VAR_NAME}`
- 예: `/dev/accounts-backend/DATABASE_URL`, `/dev/service-gateway/UPSTREAM_URL`
- ExternalSecret에서 경로 prefix를 strip: `^/dev/accounts-backend/(.*)` → `$1`
- ClusterSecretStore: `aws-ssm` (통합 1개)

### Health Checks
- Spring Boot actuator: `/actuator/health/liveness`, `/actuator/health/readiness`
- Generic default: `/healthz/liveness`, `/healthz/readiness`

## ANTI-PATTERNS

| DON'T | DO INSTEAD |
|-------|------------|
| Hardcode secrets in YAML | Use ExternalSecret + AWS SSM |
| Edit `charts/app/` for one service | Override in `values.yaml` |
| Skip sync-wave annotations | Always set appropriate wave |
| Deploy to wrong namespace | Namespace = environment (dev/prod) |
| Use Deployment | Use Argo Rollout (blue-green) |

## COMMANDS

```bash
# Bootstrap new cluster
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
./bootstrap.sh

# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Force sync application
kubectl -n argocd patch app <app-name> -p '{"operation":{"sync":{}}}' --type merge

# Check Cilium status
kubectl -n kube-system exec -it ds/cilium -- cilium status
```

## NOTES

- **NLB Source IP**: Disabled (Cloudflare proxy provides IP via headers)
- **Image registry**: ghcr.io/square-kr/* (private, requires pull-secret)
- **Rollout strategy**: Blue-green via Argo Rollouts
- **Documentation language**: Korean (한국어)
- **Helm diff plugin**: Required for `helmfile diff` (`helm plugin install https://github.com/databus23/helm-diff`)
