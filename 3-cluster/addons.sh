#!/bin/bash

# Output colors
GREEN='\033[32;1m'
YELLOW='\033[33;1m'
RED='\033[31;1m'
CYAN='\033[36;1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]  $1${NC}"; }
log_warn()  { echo -e "${YELLOW}[WARN]  $1${NC}"; }
log_step()  { echo -e "${CYAN}[STEP]  $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

echo -e "${CYAN}"
echo '  ╔═══════════════════════════════════════════════════╗'
echo '  ║   GitOps + Observability Stack Installer          ║'
echo '  ║   ArgoCD + Forgejo + Prometheus + Grafana         ║'
echo '  ║   github.com/martinbrendl/rke2-proxmox                ║'
echo '  ╚═══════════════════════════════════════════════════╝'
echo -e "${NC}"

#############################################
# DEFAULTS — override via config.env         #
# (see config.env.example in repo root)      #
#############################################

# Grafana admin password
grafanaAdminPassword=admin

# Forgejo admin credentials
forgejoAdminUsername=forgejo-admin
forgejoAdminPassword=changeme

# ---- Load local config.env (gitignored, overrides defaults above) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for cfg in "$SCRIPT_DIR/config.env" "$SCRIPT_DIR/../config.env" "$HOME/config.env"; do
  if [ -f "$cfg" ]; then
    echo "Loading config from $cfg"
    . "$cfg"
    break
  fi
done

#############################################
#            DO NOT EDIT BELOW              #
#############################################

# ============================================================
# PREREQUISITES
# ============================================================
log_step "Verifying prerequisites..."

if ! command -v kubectl &> /dev/null; then
  log_error "kubectl not found. Run rke2-cilium.sh first."
  exit 1
fi

if ! kubectl get nodes &>/dev/null; then
  log_error "Cannot reach cluster. Run rke2-cilium.sh first."
  exit 1
fi

if ! command -v helm &> /dev/null; then
  log_error "Helm not found. Run rke2-cilium.sh first."
  exit 1
fi

log_info "Cluster is reachable:"
kubectl get nodes

# ============================================================
# ADD ALL HELM REPOS
# ============================================================
log_step "Adding Helm repositories..."

helm repo add argo https://argoproj.github.io/argo-helm || {
  log_error "Failed to add ArgoCD Helm repo"
  exit 1
}

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || {
  log_error "Failed to add Prometheus Helm repo"
  exit 1
}

helm repo update
log_info "All Helm repositories added and updated"

# ============================================================
# STEP 1: Forgejo (self-hosted Git)
# ============================================================
log_step "Step 1/4: Installing Forgejo..."

# NOTE: persistence requires a StorageClass (e.g. Longhorn from 1-cluster).
# Without one, we use emptyDir (data lost on pod restart).
# Create values file for Forgejo (complex affinity rules don't work well with --set)
cat > /tmp/forgejo-values.yaml <<FVAL
service:
  http:
    type: LoadBalancer
  ssh:
    type: ClusterIP
gitea:
  admin:
    username: ${forgejoAdminUsername}
    password: ${forgejoAdminPassword}
persistence:
  enabled: true
  size: 10Gi
  storageClass: longhorn
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
FVAL

helm install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
  --namespace forgejo \
  --create-namespace \
  -f /tmp/forgejo-values.yaml \
  --wait \
  --timeout 10m

if [ $? -ne 0 ]; then
  log_error "Forgejo installation failed!"
  exit 1
fi

log_info "Forgejo installed"

FORGEJO_IP=""
log_info "Waiting for Forgejo LoadBalancer IP..."
while [[ -z "$FORGEJO_IP" ]]; do
  FORGEJO_IP=$(kubectl get svc forgejo-http -n forgejo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  sleep 5
done
log_info "Forgejo available at: http://$FORGEJO_IP:3000"

# ============================================================
# STEP 2: ArgoCD (GitOps)
# ============================================================
log_step "Step 2/4: Installing ArgoCD..."

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set server.service.type=LoadBalancer \
  --set configs.params."server\.insecure"=true \
  --wait \
  --timeout 10m

if [ $? -ne 0 ]; then
  log_error "ArgoCD installation failed!"
  exit 1
fi

log_info "ArgoCD installed"

ARGOCD_IP=""
log_info "Waiting for ArgoCD LoadBalancer IP..."
while [[ -z "$ARGOCD_IP" ]]; do
  ARGOCD_IP=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  sleep 5
done
log_info "ArgoCD available at: http://$ARGOCD_IP"

# Get ArgoCD initial admin password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
log_info "ArgoCD admin password: $ARGOCD_PASS"

# ============================================================
# STEP 3: Prometheus + Grafana (kube-prometheus-stack)
# ============================================================
log_step "Step 3/4: Installing Prometheus + Grafana..."

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.service.type=LoadBalancer \
  --set grafana.adminPassword="$grafanaAdminPassword" \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --wait \
  --timeout 10m

if [ $? -ne 0 ]; then
  log_error "Prometheus + Grafana installation failed!"
  exit 1
fi

log_info "Prometheus + Grafana installed"

GRAFANA_IP=""
log_info "Waiting for Grafana LoadBalancer IP..."
while [[ -z "$GRAFANA_IP" ]]; do
  GRAFANA_IP=$(kubectl get svc monitoring-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  sleep 5
done
log_info "Grafana available at: http://$GRAFANA_IP"

# ============================================================
# STEP 4: Verify all services
# ============================================================
log_step "Step 4/4: Verifying all services..."

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ADDONS INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}Services:${NC}"
echo ""
echo -e "${GREEN}  Forgejo:     http://$FORGEJO_IP:3000${NC}"
echo -e "${YELLOW}    Username: forgejo-admin / Password: changeme${NC}"
echo ""
echo -e "${GREEN}  ArgoCD:      http://$ARGOCD_IP${NC}"
echo -e "${YELLOW}    Username: admin / Password: $ARGOCD_PASS${NC}"
echo ""
echo -e "${GREEN}  Grafana:     http://$GRAFANA_IP${NC}"
echo -e "${YELLOW}    Username: admin / Password: $grafanaAdminPassword${NC}"
echo ""
echo -e "${CYAN}Prometheus (ClusterIP only — access via Grafana or port-forward):${NC}"
echo -e "${GREEN}  kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090${NC}"
echo ""
echo -e "${CYAN}All LoadBalancer services:${NC}"
kubectl get svc -A --field-selector spec.type=LoadBalancer
echo ""
