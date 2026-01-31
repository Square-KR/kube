#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || error "kubectl not found"
command -v helmfile >/dev/null 2>&1 || error "helmfile not found"

# Check Doppler tokens
if [[ -z "${DOPPLER_TOKEN_INFRA:-}" ]]; then
  error "DOPPLER_TOKEN_INFRA environment variable is required"
fi
if [[ -z "${DOPPLER_TOKEN_DEV:-}" ]]; then
  error "DOPPLER_TOKEN_DEV environment variable is required"
fi
if [[ -z "${DOPPLER_TOKEN_PROD:-}" ]]; then
  error "DOPPLER_TOKEN_PROD environment variable is required"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Install Cilium CNI
log "Installing Cilium CNI..."
helmfile apply --file "$SCRIPT_DIR/bootstrap/cilium/helmfile.yaml" --quiet

log "Waiting for Cilium to be ready..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=cilium-agent -n kube-system --timeout=300s

# 2. Install ArgoCD
log "Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helmfile apply --file "$SCRIPT_DIR/bootstrap/argocd/helmfile.yaml" --quiet

log "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# 3. Create Doppler token secrets
log "Creating Doppler token secrets..."
kubectl create secret generic doppler-token-infrastructure \
  --namespace kube-system \
  --from-literal=token="$DOPPLER_TOKEN_INFRA" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic doppler-token-dev \
  --namespace kube-system \
  --from-literal=token="$DOPPLER_TOKEN_DEV" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic doppler-token-prod \
  --namespace kube-system \
  --from-literal=token="$DOPPLER_TOKEN_PROD" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Apply root application
log "Applying root application..."
kubectl apply -f "$SCRIPT_DIR/root.yaml"

# Done
echo ""
log "Bootstrap complete! ArgoCD will now sync all applications."
echo ""
echo "  ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Password:  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
