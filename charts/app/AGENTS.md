# GENERIC APP HELM CHART

## OVERVIEW

Reusable Helm chart for all microservice workloads. Argo Rollout (blue-green), HPA, PDB.

## TEMPLATES

| File | Resource | Purpose |
|------|----------|---------|
| `rollout.yaml` | Argo Rollout | Blue-green deployment strategy |
| `service.yaml` | Service | ClusterIP, port 80 → container port |
| `hpa.yaml` | HorizontalPodAutoscaler | CPU-based scaling (if enabled) |
| `pdb.yaml` | PodDisruptionBudget | Availability during disruptions |

## VALUES REFERENCE

```yaml
# Required
image:
  name: ghcr.io/square-kr/<service>
  version: <commit-sha>

# Port configuration
port: 3000                    # Container port
healthCheck:
  port: ""                    # Override health port (default: same as port)
  liveness: /healthz/liveness
  readiness: /healthz/readiness

# Resources
resources:
  cpu: "100m"                 # Request only
  memory: "128Mi"             # Request + limit

# Secrets (mounted as envFrom)
secrets:
  - <secret-name>             # ExternalSecret target name

# Image pull (private registry)
imagePullSecrets:
  - ghcr-pull-secret

# Scaling (disabled by default)
hpa:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 50

# Disruption budget (disabled by default)
pdb:
  enabled: false
  minAvailable: "50%"
```

## CONVENTIONS

- **No replicas when HPA enabled**: `spec.replicas` omitted if `hpa.enabled`
- **Topology spread**: Pods spread across nodes (`maxSkew: 1`)
- **Revision history**: 2 revisions kept
- **Auto-reload**: `reloader.stakater.com/auto: "true"` annotation
- **OTEL endpoint**: Injected via `HOST_IP` fieldRef

## MODIFYING CHART

- **Service-specific changes**: Override in `projects/{service}/{env}/values.yaml`
- **Global changes**: Edit templates here (affects ALL services)
- **New template**: Add to `templates/`, update `values.yaml` defaults
