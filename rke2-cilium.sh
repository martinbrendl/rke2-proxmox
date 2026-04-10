#!/bin/bash

# Output colors
GREEN='\033[32;1m'
YELLOW='\033[33;1m'
RED='\033[31;1m'
CYAN='\033[36;1m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]  $1${NC}"; }
log_warn()  { echo -e "${YELLOW}[WARN]  $1${NC}"; }
log_step()  { echo -e "${CYAN}[STEP]  $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

echo -e "${CYAN}"
echo '  ╔═══════════════════════════════════════════════════╗'
echo '  ║   RKE2 HA Cluster + Rancher Automated Installer  ║'
echo '  ║   Proxmox + Terraform + Kube-VIP + Cilium CNI    ║'
echo '  ║   github.com/martinbrendl/rke2-proxmox            ║'
echo '  ╚═══════════════════════════════════════════════════╝'
echo -e "${NC}"


#############################################
# YOU SHOULD ONLY NEED TO EDIT THIS SECTION #
#############################################

# Node IP addresses
admin=10.0.0.210        # Admin node (runs the installer script)
master1=10.0.0.211      # Master 1 (first control-plane node)
master2=10.0.0.212      # Master 2
master3=10.0.0.213      # Master 3
worker1=10.0.0.214      # Worker 1
worker2=10.0.0.215      # Worker 2

# SSH user on remote machines
user=ubuntu

# Virtual IP address (kube-vip) - critical for HA
vip=10.0.0.220

# Master nodes array
allmasters=($master1 $master2 $master3)
masters=($master2 $master3)               # Masters without master1 (these will join)

# Worker nodes array
workers=($worker1 $worker2)

# All nodes array
all=($master1 $master2 $master3 $worker1 $worker2)

# Cilium LB-IPAM range (replaces MetalLB)
lbrangeStart=10.0.0.221
lbrangeStop=10.0.0.230

# SSH key filename
certName=id_ed25519

# Rancher hostname (with Let's Encrypt SSL)
rancherHostname=rancher.xbm.cz

# Email for Let's Encrypt (required for certificate)
letsencryptEmail=info@xbm.cz

#############################################
#            DO NOT EDIT BELOW              #
#############################################

# ============================================================
# PREREQUISITES
# ============================================================
log_step "Synchronizing system time (NTP)..."
sudo timedatectl set-ntp off
sudo timedatectl set-ntp on

# Detect network interface (first non-lo interface)
interface=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
log_info "Detected network interface: $interface"

# Move SSH certs to ~/.ssh and change permissions
log_step "Copying SSH keys to ~/.ssh..."
cp /home/$user/{$certName,$certName.pub} /home/$user/.ssh 2>/dev/null || true
chmod 600 /home/$user/.ssh/$certName
chmod 644 /home/$user/.ssh/$certName.pub

# Install Kubectl if not already present
if ! command -v kubectl &> /dev/null; then
    log_step "Kubectl not found, installing..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    log_info "Kubectl installed"
else
    log_info "Kubectl already installed"
fi

# Create SSH Config file to ignore checking (don't use in production!)
log_step "Configuring SSH (StrictHostKeyChecking)..."
mkdir -p ~/.ssh
grep -qxF 'StrictHostKeyChecking no' ~/.ssh/config 2>/dev/null || echo 'StrictHostKeyChecking no' >> ~/.ssh/config

# Distribute SSH keys to all nodes
log_step "Distributing SSH keys to all nodes..."
for node in "${all[@]}"; do
  log_info "  -> $node"
  ssh-copy-id -i ~/.ssh/$certName $user@$node 2>/dev/null
done

# ============================================================
# STEP 1: Kube-VIP manifest + RKE2 config + Cilium config
# ============================================================
log_step "Step 1/9: Preparing Kube-VIP manifest, RKE2 config and Cilium config..."

sudo mkdir -p /var/lib/rancher/rke2/server/manifests

# Generate kube-vip manifest (inline - no external dependencies)
cat > $HOME/kube-vip.yaml <<KUBEVIP
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  containers:
  - args:
    - manager
    env:
    - name: vip_arp
      value: "true"
    - name: port
      value: "6443"
    - name: vip_interface
      value: "$interface"
    - name: vip_cidr
      value: "32"
    - name: cp_enable
      value: "true"
    - name: cp_namespace
      value: kube-system
    - name: vip_ddns
      value: "false"
    - name: svc_enable
      value: "true"
    - name: vip_leaderelection
      value: "true"
    - name: vip_leaseduration
      value: "5"
    - name: vip_renewdeadline
      value: "3"
    - name: vip_retryperiod
      value: "1"
    - name: address
      value: "$vip"
    image: ghcr.io/kube-vip/kube-vip:v0.8.7
    imagePullPolicy: Always
    name: kube-vip
    securityContext:
      capabilities:
        add:
        - NET_ADMIN
        - NET_RAW
        - SYS_TIME
    volumeMounts:
    - mountPath: /etc/kubernetes/admin.conf
      name: kubeconfig
  hostAliases:
  - hostnames:
    - kubernetes
    ip: 127.0.0.1
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/rancher/rke2/rke2.yaml
    name: kubeconfig
KUBEVIP
sudo cp $HOME/kube-vip.yaml /var/lib/rancher/rke2/server/manifests/kube-vip.yaml

# Generate Cilium HelmChartConfig (customizes the built-in RKE2 Cilium chart)
cat > $HOME/rke2-cilium-config.yaml <<CILIUMCFG
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true
    k8sServiceHost: "$master1"
    k8sServicePort: 6443
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
    l2announcements:
      enabled: true
    externalIPs:
      enabled: true
    operator:
      replicas: 1
CILIUMCFG
sudo cp $HOME/rke2-cilium-config.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml

mkdir -p ~/.kube

# Create RKE2 config with Cilium CNI
sudo mkdir -p /etc/rancher/rke2
cat > config.yaml <<CONF
node-name: master1
tls-san:
  - $vip
  - $master1
  - $master2
  - $master3
write-kubeconfig-mode: "0644"
cni: cilium
disable-kube-proxy: true
CONF
sudo cp ~/config.yaml /etc/rancher/rke2/config.yaml
log_info "Kube-VIP manifest, Cilium config, and config.yaml ready"

# Update PATH (idempotent - no duplicates)
grep -qF '/var/lib/rancher/rke2/bin' ~/.bashrc || {
  echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc
  echo 'export PATH=${PATH}:/var/lib/rancher/rke2/bin' >> ~/.bashrc
  echo 'alias k=kubectl' >> ~/.bashrc
}
source ~/.bashrc

# ============================================================
# STEP 2: Copy files to all master nodes
# ============================================================
log_step "Step 2/9: Copying kube-vip.yaml, Cilium config, RKE2 config and SSH keys to master nodes..."

for newnode in "${allmasters[@]}"; do
  log_info "  -> $newnode"
  scp -i ~/.ssh/$certName $HOME/kube-vip.yaml $user@$newnode:~/kube-vip.yaml
  scp -i ~/.ssh/$certName $HOME/rke2-cilium-config.yaml $user@$newnode:~/rke2-cilium-config.yaml
  scp -i ~/.ssh/$certName $HOME/config.yaml $user@$newnode:~/config.yaml
  scp -i ~/.ssh/$certName ~/.ssh/{$certName,$certName.pub} $user@$newnode:~/.ssh
done
log_info "Files copied to all master nodes"

# ============================================================
# STEP 3: Install RKE2 on master1
# ============================================================
log_step "Step 3/9: Installing RKE2 + Cilium on master1 ($master1)... (this may take 3-8 minutes)"

ssh -i ~/.ssh/$certName $user@$master1 "sudo bash" <<EOF
mkdir -p /var/lib/rancher/rke2/server/manifests
mv /home/$user/kube-vip.yaml /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
mv /home/$user/rke2-cilium-config.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
mkdir -p /etc/rancher/rke2
mv /home/$user/config.yaml /etc/rancher/rke2/config.yaml
grep -qF '/var/lib/rancher/rke2/bin' /home/$user/.bashrc || {
  echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /home/$user/.bashrc
  echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' >> /home/$user/.bashrc
  echo 'alias k=kubectl' >> /home/$user/.bashrc
}
curl -sfL https://get.rke2.io | sh -
systemctl enable rke2-server.service
systemctl start rke2-server.service
mkdir -p /home/$user/.ssh
echo "StrictHostKeyChecking no" > /home/$user/.ssh/config
chown $user:$user /home/$user/.ssh/config
sudo -u $user ssh-copy-id -i /home/$user/.ssh/$certName $user@$admin < /dev/null
sudo -u $user ssh -i /home/$user/.ssh/$certName $user@$admin 'mkdir -p ~/.kube && sudo rm -f ~/.kube/rke2.yaml && sudo chown -R \$(id -u):\$(id -g) ~/.kube' < /dev/null
cp /var/lib/rancher/rke2/server/token /tmp/rke2-token
cp /etc/rancher/rke2/rke2.yaml /tmp/rke2.yaml
chmod 644 /tmp/rke2-token /tmp/rke2.yaml
sudo -u $user scp -i /home/$user/.ssh/$certName /tmp/rke2-token $user@$admin:~/token
sudo -u $user scp -i /home/$user/.ssh/$certName /tmp/rke2.yaml $user@$admin:~/.kube/rke2.yaml
rm -f /tmp/rke2-token /tmp/rke2.yaml
EOF
log_info "Master1 installation complete"

# Wait for master1 registration endpoint (port 9345)
log_step "Waiting for master1 registration endpoint (port 9345)..."
attempt=0
while ! ssh -i ~/.ssh/$certName $user@$master1 'sudo ss -tlnp | grep -q 9345' 2>/dev/null; do
  attempt=$((attempt + 1))
  echo -e "${YELLOW}  Attempt $attempt - master1:9345 not available yet, waiting 5s...${NC}"
  sleep 5
done
log_info "Master1 registration endpoint ready (port 9345 open)"

# Wait for master1 Ready state (required before joining master2/3)
log_step "Waiting for master1 Ready state (required before joining other masters)..."
attempt=0
while true; do
  attempt=$((attempt + 1))
  node_status=$(ssh -i ~/.ssh/$certName $user@$master1 'sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null' < /dev/null 2>/dev/null || true)
  if echo "$node_status" | grep -q " Ready "; then
    break
  fi
  echo -e "${YELLOW}  Attempt $attempt - master1 still NotReady, waiting 10s...${NC}"
  if [ -n "$node_status" ]; then
    echo -e "${YELLOW}  Status: $(echo "$node_status" | grep -v NAME | head -1)${NC}"
  fi
  sleep 10
done
log_info "Master1 is Ready! Proceeding with master2/3 join..."

# ============================================================
# STEP 4: Configure kubectl on admin node
# ============================================================
log_step "Step 4/9: Configuring kubectl on admin node..."

token=$(cat token)
sudo cat ~/.kube/rke2.yaml | sed 's/127.0.0.1/'$master1'/g' > $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=${HOME}/.kube/config
sudo cp ~/.kube/config /etc/rancher/rke2/rke2.yaml

log_info "Kubectl configured. Current cluster state:"
kubectl get nodes

# ============================================================
# STEP 5: Kube-VIP Cloud Provider
# ============================================================
log_step "Step 5/9: Installing Kube-VIP Cloud Provider..."

kubectl apply -f https://kube-vip.io/manifests/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml
log_info "Kube-VIP Cloud Provider installed"

# ============================================================
# STEP 6: Join additional masters (master2, master3)
# ============================================================
log_step "Step 6/9: Joining additional master nodes..."

masterindex=2
for newnode in "${masters[@]}"; do
  nodename="master${masterindex}"
  log_info "Joining master node $newnode ($nodename)... (this may take 3-8 minutes)"
  ssh -i ~/.ssh/$certName $user@$newnode "sudo bash" <<EOF
/usr/local/bin/rke2-uninstall.sh 2>/dev/null || true
rm -rf /etc/rancher /var/lib/rancher
mkdir -p /var/lib/rancher/rke2/server/manifests
cp /home/$user/rke2-cilium-config.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<INNEREOF
node-name: $nodename
token: $token
server: https://$master1:9345
tls-san:
  - $vip
  - $master1
  - $master2
  - $master3
cni: cilium
disable-kube-proxy: true
INNEREOF
curl -sfL https://get.rke2.io | sh -
mkdir -p /etc/systemd/system/rke2-server.service.d
cat > /etc/systemd/system/rke2-server.service.d/override.conf <<SVCEOF
[Service]
TimeoutStartSec=600
SVCEOF
systemctl daemon-reload
systemctl enable rke2-server.service
systemctl start rke2-server.service
EOF
  log_info "Master node $newnode added"

  # Wait for node to actually join the cluster
  log_info "Waiting for $newnode to appear in cluster..."
  attempt=0
  while ! kubectl get nodes -o wide 2>/dev/null | grep -q "$newnode"; do
    attempt=$((attempt + 1))
    if [ $attempt -gt 72 ]; then
      log_warn "Node $newnode didn't join within 6 minutes, continuing..."
      break
    fi
    echo -e "${YELLOW}  Attempt $attempt - waiting 5s for $newnode join...${NC}"
    sleep 5
  done
  masterindex=$((masterindex + 1))
done

log_info "Cluster state after joining masters:"
kubectl get nodes

# ============================================================
# STEP 7: Join worker nodes
# ============================================================
log_step "Step 7/9: Joining worker nodes..."

workerindex=1
for newnode in "${workers[@]}"; do
  nodename="worker${workerindex}"
  log_info "Joining worker node $newnode ($nodename)... (this may take 2-5 minutes)"
  ssh -i ~/.ssh/$certName $user@$newnode "sudo bash" <<EOF
/usr/local/bin/rke2-agent-uninstall.sh 2>/dev/null || true
rm -rf /etc/rancher /var/lib/rancher
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<INNEREOF
node-name: $nodename
token: $token
server: https://$vip:9345
node-label:
  - worker=true
  - longhorn=true
INNEREOF
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
mkdir -p /etc/systemd/system/rke2-agent.service.d
cat > /etc/systemd/system/rke2-agent.service.d/override.conf <<SVCEOF
[Service]
TimeoutStartSec=600
SVCEOF
systemctl daemon-reload
systemctl enable rke2-agent.service
systemctl start rke2-agent.service
EOF
  log_info "Worker node $newnode added"
  workerindex=$((workerindex + 1))
done

log_info "Cluster state after joining workers:"
kubectl get nodes

# ============================================================
# STEP 8: Cilium LB-IPAM + L2 Announcements (replaces MetalLB)
# ============================================================
log_step "Step 8/9: Configuring Cilium LB-IPAM and L2 Announcements..."

# Wait for Cilium to be fully running
log_info "Waiting for Cilium pods to be ready..."
attempt=0
while true; do
  attempt=$((attempt + 1))
  ready_count=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  if [ "$ready_count" -ge "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
    break
  fi
  if [ $attempt -gt 60 ]; then
    log_warn "Cilium not fully ready after 5 minutes, continuing anyway..."
    break
  fi
  echo -e "${YELLOW}  Attempt $attempt - Cilium agents ready: $ready_count/$total_nodes, waiting 5s...${NC}"
  sleep 5
done
log_info "Cilium is running"

# Wait for Cilium CRDs to be available
log_info "Waiting for Cilium CRDs..."
attempt=0
while ! kubectl get crd ciliumloadbalancerippools.cilium.io &>/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -gt 60 ]; then
    log_warn "CiliumLoadBalancerIPPool CRD not found after 300s, continuing..."
    break
  fi
  echo -e "${YELLOW}  Attempt $attempt - waiting 5s for Cilium CRDs...${NC}"
  sleep 5
done

# Apply Cilium LoadBalancer IP Pool (replaces MetalLB IPAddressPool)
cat > $HOME/cilium-lb-ippool.yaml <<LBPOOL
apiVersion: "cilium.io/v2"
kind: CiliumLoadBalancerIPPool
metadata:
  name: first-pool
spec:
  blocks:
    - start: "$lbrangeStart"
      stop: "$lbrangeStop"
LBPOOL
kubectl apply -f $HOME/cilium-lb-ippool.yaml

# Apply Cilium L2 Announcement Policy (replaces MetalLB L2Advertisement)
cat > $HOME/cilium-l2-policy.yaml <<L2POL
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: l2-policy
spec:
  externalIPs: true
  loadBalancerIPs: true
  interfaces:
    - ^eth[0-9]+
L2POL
kubectl apply -f $HOME/cilium-l2-policy.yaml

log_info "Cilium LB-IPAM configured (IP range: $lbrangeStart - $lbrangeStop)"

# ============================================================
# STEP 9: Rancher + Cert-Manager + Helm
# ============================================================
log_step "Step 9/9: Installing Helm, Cert-Manager and Rancher..."

# Helm
if ! command -v helm &> /dev/null; then
    log_info "Installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh
else
    log_info "Helm already installed"
fi

# Rancher Helm Repo
log_info "Adding Rancher Helm repo..."
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
kubectl create namespace cattle-system 2>/dev/null || true

# Cert-Manager
log_info "Installing Cert-Manager v1.13.2..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.crds.yaml
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.13.2

log_info "Waiting for Cert-Manager pods..."
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=300s

# Rancher
log_info "Installing Rancher (hostname: $rancherHostname)..."
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=$rancherHostname \
  --set bootstrapPassword=admin \
  --set ingress.tls.source=letsEncrypt \
  --set letsEncrypt.email=$letsencryptEmail

log_info "Waiting for Rancher deployment..."
kubectl -n cattle-system rollout status deploy/rancher --timeout=600s
kubectl -n cattle-system get deploy rancher

# Rancher LoadBalancer
log_info "Creating Rancher LoadBalancer..."
kubectl expose deployment rancher --name=rancher-lb --port=443 --type=LoadBalancer -n cattle-system 2>/dev/null || true

log_info "Waiting for LoadBalancer IP assignment (Cilium LB-IPAM)..."
while [[ -z $(kubectl get svc rancher-lb -n cattle-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]; do
  sleep 5
  echo -e "${YELLOW}  Waiting for Cilium LB-IPAM IP assignment...${NC}"
done

# Hubble UI LoadBalancer
log_info "Exposing Hubble UI via LoadBalancer..."
kubectl expose deployment hubble-ui --name=hubble-ui-lb --port=80 --target-port=8081 --type=LoadBalancer -n kube-system 2>/dev/null || true

log_info "Waiting for Hubble UI LoadBalancer IP..."
while [[ -z $(kubectl get svc hubble-ui-lb -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]; do
  sleep 5
  echo -e "${YELLOW}  Waiting for Hubble UI LB IP assignment...${NC}"
done

# ============================================================
# DONE
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}Cluster nodes:${NC}"
kubectl get nodes -o wide
echo ""
echo -e "${CYAN}Cilium status:${NC}"
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent -o wide
echo ""
echo -e "${CYAN}Hubble status:${NC}"
kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-ui -o wide
kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-relay -o wide
echo ""
echo -e "${CYAN}Cilium LB-IPAM pools:${NC}"
kubectl get ciliumloadbalancerippool
echo ""
echo -e "${CYAN}Rancher services:${NC}"
kubectl get svc -n cattle-system
echo ""
RANCHER_IP=$(kubectl get svc rancher-lb -n cattle-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
echo -e "${GREEN}Rancher URL:  https://$rancherHostname${NC}"
echo -e "${GREEN}Rancher LB IP: $RANCHER_IP${NC}"
echo -e "${GREEN}Bootstrap password: admin${NC}"
echo -e "${YELLOW}Don't forget to set DNS: $rancherHostname -> $RANCHER_IP${NC}"
echo ""
HUBBLE_IP=$(kubectl get svc hubble-ui-lb -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
echo -e "${CYAN}Hubble UI:${NC}"
echo -e "${GREEN}  http://$HUBBLE_IP${NC}"
echo ""
