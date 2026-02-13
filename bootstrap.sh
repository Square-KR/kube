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

# Check AWS credentials
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  error "AWS_ACCESS_KEY_ID environment variable is required"
fi
if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  error "AWS_SECRET_ACCESS_KEY environment variable is required"
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

# 3. Create AWS SSM credentials secret
log "Creating AWS SSM credentials secret..."
kubectl create secret generic aws-ssm-credentials \
  --namespace kube-system \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
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
