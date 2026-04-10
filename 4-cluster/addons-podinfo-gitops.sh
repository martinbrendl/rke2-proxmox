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
echo '  ║   Podinfo GitOps Deployment (Forgejo + ArgoCD)    ║'
echo '  ║   Self-hosted Git → ArgoCD auto-sync              ║'
echo '  ║   github.com/martinbrendl/rke2-proxmox            ║'
echo '  ╚═══════════════════════════════════════════════════╝'
echo -e "${NC}"

#############################################
# DEFAULTS — override via config.env         #
# (see config.env.example in repo root)      #
#############################################

# Forgejo admin credentials (must match those used during Forgejo install)
forgejoAdminUsername=forgejo-admin
forgejoAdminPassword=changeme

# Repository to create in Forgejo
forgejoRepoName=podinfo

# Kubernetes namespaces
forgejoNamespace=forgejo
argocdNamespace=argocd
appsNamespace=apps

# Forgejo HTTP service name (created by forgejo-helm chart)
forgejoServiceName=forgejo-http

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

command -v kubectl >/dev/null 2>&1 || { log_error "kubectl not found. Run rke2-cilium.sh first."; exit 1; }
command -v git     >/dev/null 2>&1 || { log_error "git not found. Install it: sudo apt install -y git"; exit 1; }
command -v curl    >/dev/null 2>&1 || { log_error "curl not found. Install it: sudo apt install -y curl"; exit 1; }

kubectl get nodes >/dev/null 2>&1 || { log_error "Cannot reach cluster."; exit 1; }

# Check Forgejo is installed
if ! kubectl get svc -n "$forgejoNamespace" "$forgejoServiceName" >/dev/null 2>&1; then
  log_error "Forgejo service '$forgejoServiceName' not found in namespace '$forgejoNamespace'."
  log_error "Run 3-cluster/addons.sh first to install Forgejo + ArgoCD."
  exit 1
fi

# Check ArgoCD is installed
if ! kubectl get svc -n "$argocdNamespace" argocd-server >/dev/null 2>&1; then
  log_error "ArgoCD service not found in namespace '$argocdNamespace'."
  log_error "Run 3-cluster/addons.sh first to install Forgejo + ArgoCD."
  exit 1
fi

log_info "Cluster + Forgejo + ArgoCD reachable"

# ============================================================
# STEP 1: Discover Forgejo LoadBalancer IP (for admin access)
# ============================================================
log_step "Step 1/6: Discovering Forgejo LoadBalancer IP..."

FORGEJO_LB=""
for i in {1..30}; do
  FORGEJO_LB=$(kubectl get svc -n "$forgejoNamespace" "$forgejoServiceName" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [ -n "$FORGEJO_LB" ]; then break; fi
  sleep 2
done

if [ -z "$FORGEJO_LB" ]; then
  log_error "Forgejo has no LoadBalancer IP. Is Cilium LB-IPAM working?"
  exit 1
fi

log_info "Forgejo LoadBalancer: http://${FORGEJO_LB}:3000"

# Wait until Forgejo API responds
log_info "Waiting for Forgejo API to respond..."
for i in {1..60}; do
  if curl -s -o /dev/null -w '%{http_code}' "http://${FORGEJO_LB}:3000/api/v1/version" | grep -q '200'; then
    log_info "Forgejo API is up"
    break
  fi
  sleep 2
done

# ============================================================
# STEP 2: Create Forgejo repository via API
# ============================================================
log_step "Step 2/6: Creating Forgejo repository '${forgejoRepoName}'..."

# Check if repo already exists
REPO_CHECK=$(curl -s -o /dev/null -w '%{http_code}' \
  -u "${forgejoAdminUsername}:${forgejoAdminPassword}" \
  "http://${FORGEJO_LB}:3000/api/v1/repos/${forgejoAdminUsername}/${forgejoRepoName}")

if [ "$REPO_CHECK" = "200" ]; then
  log_warn "Repo already exists — skipping creation"
else
  CREATE_RESP=$(curl -s -X POST \
    -u "${forgejoAdminUsername}:${forgejoAdminPassword}" \
    -H "Content-Type: application/json" \
    "http://${FORGEJO_LB}:3000/api/v1/user/repos" \
    -d "{\"name\":\"${forgejoRepoName}\",\"description\":\"Podinfo GitOps demo\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}")

  if echo "$CREATE_RESP" | grep -q '"name"'; then
    log_info "Repository created: ${forgejoAdminUsername}/${forgejoRepoName}"
  else
    log_error "Failed to create repo:"
    echo "$CREATE_RESP"
    exit 1
  fi
fi

# ============================================================
# STEP 3: Clone repo, add podinfo manifests, push
# ============================================================
log_step "Step 3/6: Pushing podinfo manifests to Forgejo..."

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
cd "$TMPDIR"

# Use credentials in URL for this one-shot clone/push
REPO_URL="http://${forgejoAdminUsername}:${forgejoAdminPassword}@${FORGEJO_LB}:3000/${forgejoAdminUsername}/${forgejoRepoName}.git"

git clone -q "$REPO_URL" repo || { log_error "git clone failed"; exit 1; }
cd repo

git config user.email "admin@rke2-proxmox.local"
git config user.name  "Forgejo Admin"

mkdir -p apps/podinfo

cat > apps/podinfo/namespace.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: apps
  labels:
    app.kubernetes.io/managed-by: argocd
YAML

cat > apps/podinfo/deployment.yaml <<'YAML'
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
YAML

cat > apps/podinfo/service.yaml <<'YAML'
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
YAML

cat > README.md <<'EOMD'
# podinfo

Kubernetes manifests for [podinfo](https://github.com/stefanprodan/podinfo),
deployed to the `apps` namespace via ArgoCD (GitOps).

Structure:
- `apps/podinfo/namespace.yaml` — creates the `apps` namespace
- `apps/podinfo/deployment.yaml` — 2 replicas, probes, limits
- `apps/podinfo/service.yaml` — LoadBalancer service on port 80

Edit these files and push — ArgoCD will auto-sync changes to the cluster.
EOMD

# Commit + push (only if there are changes)
git add .
if git diff --cached --quiet; then
  log_warn "No changes to commit (manifests already present)"
else
  git commit -q -m "Add podinfo manifests"
  git push -q origin main || { log_error "git push failed"; exit 1; }
  log_info "Manifests pushed to Forgejo"
fi

cd /
rm -rf "$TMPDIR"
trap - EXIT

# ============================================================
# STEP 4: Register Forgejo repo in ArgoCD (with credentials)
# ============================================================
log_step "Step 4/6: Registering Forgejo repo as ArgoCD source..."

# Internal cluster URL that ArgoCD will use to fetch manifests
INTERNAL_REPO_URL="http://${forgejoServiceName}.${forgejoNamespace}.svc.cluster.local:3000/${forgejoAdminUsername}/${forgejoRepoName}.git"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: forgejo-podinfo-repo
  namespace: ${argocdNamespace}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${INTERNAL_REPO_URL}
  username: ${forgejoAdminUsername}
  password: ${forgejoAdminPassword}
EOF

log_info "ArgoCD repo secret registered: ${INTERNAL_REPO_URL}"

# ============================================================
# STEP 5: Create ArgoCD Application
# ============================================================
log_step "Step 5/6: Creating ArgoCD Application 'podinfo'..."

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: ${argocdNamespace}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${INTERNAL_REPO_URL}
    targetRevision: main
    path: apps/podinfo
  destination:
    server: https://kubernetes.default.svc
    namespace: ${appsNamespace}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

log_info "ArgoCD Application created"

# ============================================================
# STEP 6: Wait for ArgoCD sync and Podinfo LoadBalancer IP
# ============================================================
log_step "Step 6/6: Waiting for ArgoCD sync..."

# Wait for Application to reach Synced + Healthy
for i in {1..60}; do
  SYNC_STATUS=$(kubectl get application podinfo -n "$argocdNamespace" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null)
  HEALTH_STATUS=$(kubectl get application podinfo -n "$argocdNamespace" \
    -o jsonpath='{.status.health.status}' 2>/dev/null)

  if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
    log_info "ArgoCD: Synced + Healthy"
    break
  fi
  echo "  sync=$SYNC_STATUS health=$HEALTH_STATUS ($i/60)"
  sleep 5
done

log_info "Waiting for Podinfo LoadBalancer IP..."
PODINFO_LB=""
for i in {1..30}; do
  PODINFO_LB=$(kubectl get svc -n "$appsNamespace" podinfo \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [ -n "$PODINFO_LB" ]; then break; fi
  sleep 2
done

# ============================================================
# SUMMARY
# ============================================================
echo -e "${GREEN}"
echo '  ╔═══════════════════════════════════════════════════╗'
echo '  ║        GitOps Podinfo deployment complete         ║'
echo '  ╚═══════════════════════════════════════════════════╝'
echo -e "${NC}"

echo -e "${CYAN}Forgejo repository:${NC}"
echo -e "  Web UI:       http://${FORGEJO_LB}:3000/${forgejoAdminUsername}/${forgejoRepoName}"
echo -e "  Internal URL: ${INTERNAL_REPO_URL}"
echo ""
echo -e "${CYAN}ArgoCD Application:${NC}"
kubectl get application podinfo -n "$argocdNamespace" 2>/dev/null || true
echo ""
echo -e "${CYAN}Podinfo:${NC}"
if [ -n "$PODINFO_LB" ]; then
  echo -e "  URL: ${GREEN}http://${PODINFO_LB}${NC}"
else
  echo -e "  ${YELLOW}LoadBalancer IP still pending — check: kubectl get svc -n ${appsNamespace} podinfo${NC}"
fi
echo ""
echo -e "${YELLOW}Test the GitOps loop:${NC}"
echo "  1. git clone http://${forgejoAdminUsername}@${FORGEJO_LB}:3000/${forgejoAdminUsername}/${forgejoRepoName}.git"
echo "  2. Edit apps/podinfo/deployment.yaml (e.g. change replicas to 3)"
echo "  3. git commit -am 'scale podinfo' && git push"
echo "  4. ArgoCD auto-syncs within ~3 minutes (or force: kubectl -n argocd patch app podinfo --type merge -p '{\"operation\":{\"sync\":{}}}')"
