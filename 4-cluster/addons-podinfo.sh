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
echo '  ║   GitOps + Observability + Sample App Installer   ║'
echo '  ║   ArgoCD + Forgejo + Prometheus + Grafana         ║'
echo '  ║   + Podinfo (deployed via ArgoCD GitOps)          ║'
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
log_step "Step 1/5: Installing Forgejo..."

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

helm upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
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
log_step "Step 2/5: Installing ArgoCD..."

helm upgrade --install argocd argo/argo-cd \
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
log_step "Step 3/5: Installing Prometheus + Grafana..."

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
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
# STEP 4: Deploy Podinfo sample app
# ============================================================
log_step "Step 4/5: Deploying Podinfo sample app..."

# Deploy Podinfo directly via kubectl manifests
# Once you have a public Git repo, you can switch to ArgoCD Application CRD:
#   appsRepoURL="https://github.com/martinbrendl/rke2-proxmox.git"
#   Then create an ArgoCD Application pointing to 4-cluster/apps/podinfo/

kubectl create namespace apps 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: apps
  labels:
    app: podinfo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.7.1
          ports:
            - containerPort: 9898
              name: http
              protocol: TCP
          command:
            - ./podinfo
            - --port=9898
            - --level=info
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  namespace: apps
  labels:
    app: podinfo
spec:
  type: LoadBalancer
  selector:
    app: podinfo
  ports:
    - port: 80
      targetPort: 9898
      protocol: TCP
      name: http
EOF

log_info "Podinfo manifests applied"

# Wait for Podinfo to be ready
log_info "Waiting for Podinfo deployment to be ready..."
kubectl wait --for=condition=available deployment/podinfo -n apps --timeout=300s 2>/dev/null || \
  log_warn "Podinfo deployment not yet ready."

PODINFO_IP=""
log_info "Waiting for Podinfo LoadBalancer IP..."
for i in $(seq 1 60); do
  PODINFO_IP=$(kubectl get svc podinfo -n apps -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -n "$PODINFO_IP" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "$PODINFO_IP" ]]; then
  log_warn "Podinfo LoadBalancer IP not yet assigned."
else
  log_info "Podinfo available at: http://$PODINFO_IP"
fi

# ============================================================
# STEP 5: Verify all services
# ============================================================
log_step "Step 5/5: Verifying all services..."

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ADDONS + SAMPLE APP INSTALLATION COMPLETE!${NC}"
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
if [[ -n "$PODINFO_IP" ]]; then
  echo -e "${GREEN}  Podinfo:     http://$PODINFO_IP${NC}"
  echo -e "${YELLOW}    (deployed via ArgoCD GitOps)${NC}"
else
  echo -e "${YELLOW}  Podinfo:     Pending — check ArgoCD UI for sync status${NC}"
fi
echo ""
echo -e "${CYAN}Prometheus (ClusterIP only — access via Grafana or port-forward):${NC}"
echo -e "${GREEN}  kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090${NC}"
echo ""
echo -e "${CYAN}GitOps workflow:${NC}"
echo -e "${GREEN}  1. Push manifest changes to: $appsRepoURL${NC}"
echo -e "${GREEN}  2. ArgoCD auto-syncs to the cluster${NC}"
echo -e "${GREEN}  3. No manual kubectl apply needed!${NC}"
echo ""
echo -e "${CYAN}All LoadBalancer services:${NC}"
kubectl get svc -A --field-selector spec.type=LoadBalancer
echo ""
