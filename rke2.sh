#!/bin/bash

# Barvy pro výstup
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
echo '  ║   Proxmox + Terraform + Kube-VIP + MetalLB       ║'
echo '  ║   github.com/martinbrendl/rke2-proxmox            ║'
echo '  ╚═══════════════════════════════════════════════════╝'
echo -e "${NC}"


#############################################
# YOU SHOULD ONLY NEED TO EDIT THIS SECTION #
#############################################

# IP adresy nodů
admin=10.0.0.210        # Admin node (odkud se spouští skript)
master1=10.0.0.211      # Master 1 (první control-plane node)
master2=10.0.0.212      # Master 2
master3=10.0.0.213      # Master 3
worker1=10.0.0.214      # Worker 1
worker2=10.0.0.215      # Worker 2

# Uživatel na vzdálených strojích
user=ubuntu

# Virtuální IP adresa (kube-vip) - kritické pro HA
vip=10.0.0.220

# Pole master nodů
allmasters=($master1 $master2 $master3)
masters=($master2 $master3)               # Mastery bez master1 (ty se joinují)

# Pole worker nodů
workers=($worker1 $worker2)

# Pole všech nodů
all=($master1 $master2 $master3 $worker1 $worker2)

# MetalLB IP rozsah pro LoadBalancery
lbrange=10.0.0.221-10.0.0.230

# Název SSH klíče
certName=id_ed25519

# Rancher hostname (s Let's Encrypt SSL)
rancherHostname=rancher.example.com

# E-mail pro Let's Encrypt (potřebný pro certifikát)
letsencryptEmail=admin@example.com

#############################################
#            DO NOT EDIT BELOW              #
#############################################

# ============================================================
# PREREKVIZITY
# ============================================================
log_step "Synchronizace systémového času (NTP)..."
sudo timedatectl set-ntp off
sudo timedatectl set-ntp on

# Detekce síťového rozhraní (první non-lo interface)
interface=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
log_info "Detekované síťové rozhraní: $interface"

# Move SSH certs to ~/.ssh and change permissions
log_step "Kopíruji SSH klíče do ~/.ssh..."
cp /home/$user/{$certName,$certName.pub} /home/$user/.ssh 2>/dev/null || true
chmod 600 /home/$user/.ssh/$certName
chmod 644 /home/$user/.ssh/$certName.pub

# Install Kubectl if not already present
if ! command -v kubectl &> /dev/null; then
    log_step "Kubectl nenalezen, instaluji..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    log_info "Kubectl nainstalován"
else
    log_info "Kubectl již nainstalován"
fi

# Create SSH Config file to ignore checking (don't use in production!)
log_step "Konfiguruji SSH (StrictHostKeyChecking)..."
mkdir -p ~/.ssh
grep -qxF 'StrictHostKeyChecking no' ~/.ssh/config 2>/dev/null || echo 'StrictHostKeyChecking no' >> ~/.ssh/config

# Distribute SSH keys to all nodes
log_step "Distribuuji SSH klíče na všechny nody..."
for node in "${all[@]}"; do
  log_info "  -> $node"
  ssh-copy-id -i ~/.ssh/$certName $user@$node 2>/dev/null
done

# ============================================================
# STEP 1: Kube-VIP manifest + RKE2 config
# ============================================================
log_step "Step 1/10: Příprava Kube-VIP manifestu a RKE2 config..."

sudo mkdir -p /var/lib/rancher/rke2/server/manifests

# Generuj kube-vip manifest (inline - bez externích závislostí)
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

mkdir -p ~/.kube

# Vytvoř RKE2 config (truncate - bezpečné pro opakované spuštění)
sudo mkdir -p /etc/rancher/rke2
cat > config.yaml <<CONF
node-name: master1
tls-san:
  - $vip
  - $master1
  - $master2
  - $master3
write-kubeconfig-mode: "0644"
CONF
sudo cp ~/config.yaml /etc/rancher/rke2/config.yaml
log_info "Kube-VIP manifest a config.yaml připraveny"

# Update PATH (idempotentní - nepřidává duplicity)
grep -qF '/var/lib/rancher/rke2/bin' ~/.bashrc || {
  echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc
  echo 'export PATH=${PATH}:/var/lib/rancher/rke2/bin' >> ~/.bashrc
  echo 'alias k=kubectl' >> ~/.bashrc
}
source ~/.bashrc

# ============================================================
# STEP 2: Kopíruji soubory na všechny mastery
# ============================================================
log_step "Step 2/10: Kopíruji kube-vip.yaml, config a SSH klíče na mastery..."

for newnode in "${allmasters[@]}"; do
  log_info "  -> $newnode"
  scp -i ~/.ssh/$certName $HOME/kube-vip.yaml $user@$newnode:~/kube-vip.yaml
  scp -i ~/.ssh/$certName $HOME/config.yaml $user@$newnode:~/config.yaml
  scp -i ~/.ssh/$certName ~/.ssh/{$certName,$certName.pub} $user@$newnode:~/.ssh
done
log_info "Soubory zkopírovány na všechny mastery"

# ============================================================
# STEP 3: Instalace RKE2 na master1
# ============================================================
log_step "Step 3/10: Instaluji RKE2 na master1 ($master1)... (toto může trvat 2-5 minut)"

ssh -i ~/.ssh/$certName $user@$master1 "sudo bash" <<EOF
mkdir -p /var/lib/rancher/rke2/server/manifests
mv /home/$user/kube-vip.yaml /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
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
log_info "Master1 instalace dokončena"

# Počkej než master1 zpřístupní registration endpoint (port 9345)
log_step "Čekám na master1 registration endpoint (port 9345)..."
attempt=0
while ! ssh -i ~/.ssh/$certName $user@$master1 'sudo ss -tlnp | grep -q 9345' 2>/dev/null; do
  attempt=$((attempt + 1))
  echo -e "${YELLOW}  Pokus $attempt - master1:9345 zatím nedostupný, čekám 5s...${NC}"
  sleep 5
done
log_info "Master1 registration endpoint je připraven (port 9345 otevřen)"

# Počkej než master1 bude ve stavu Ready (nutné pro join master2/3)
log_step "Čekám na master1 Ready stav (nutné pro join dalších masterů)..."
attempt=0
while true; do
  attempt=$((attempt + 1))
  node_status=$(ssh -i ~/.ssh/$certName $user@$master1 'sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null' < /dev/null 2>/dev/null || true)
  if echo "$node_status" | grep -q " Ready "; then
    break
  fi
  echo -e "${YELLOW}  Pokus $attempt - master1 zatím NotReady, čekám 10s...${NC}"
  if [ -n "$node_status" ]; then
    echo -e "${YELLOW}  Status: $(echo "$node_status" | grep -v NAME | head -1)${NC}"
  fi
  sleep 10
done
log_info "Master1 je ve stavu Ready! Pokračuji s join master2/3..."

# ============================================================
# STEP 4: Nastavení kubectl na admin nodu
# ============================================================
log_step "Step 4/10: Konfiguruji kubectl na admin nodu..."

token=$(cat token)
sudo cat ~/.kube/rke2.yaml | sed 's/127.0.0.1/'$master1'/g' > $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=${HOME}/.kube/config
sudo cp ~/.kube/config /etc/rancher/rke2/rke2.yaml

log_info "Kubectl nakonfigurován. Aktuální stav clusteru:"
kubectl get nodes

# ============================================================
# STEP 5: Kube-VIP Cloud Provider
# ============================================================
log_step "Step 5/10: Instaluji Kube-VIP Cloud Provider..."

kubectl apply -f https://kube-vip.io/manifests/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml
log_info "Kube-VIP Cloud Provider nainstalován"

# ============================================================
# STEP 6: Přidání dalších masterů (master2, master3)
# ============================================================
log_step "Step 6/10: Přidávám další master nody..."

masterindex=2
for newnode in "${masters[@]}"; do
  nodename="master${masterindex}"
  log_info "Joinuji master node $newnode ($nodename)... (toto může trvat 3-8 minut)"
  ssh -i ~/.ssh/$certName $user@$newnode "sudo bash" <<EOF
/usr/local/bin/rke2-uninstall.sh 2>/dev/null || true
rm -rf /etc/rancher /var/lib/rancher
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
  log_info "Master node $newnode přidán"

  # Počkej než se node skutečně připojí ke clusteru
  log_info "Čekám než se $newnode objeví v clusteru..."
  attempt=0
  while ! kubectl get nodes -o wide 2>/dev/null | grep -q "$newnode"; do
    attempt=$((attempt + 1))
    if [ $attempt -gt 72 ]; then
      log_warn "Node $newnode se nepřipojil do 6 minut, pokračuji..."
      break
    fi
    echo -e "${YELLOW}  Pokus $attempt - čekám 5s na join $newnode...${NC}"
    sleep 5
  done
  masterindex=$((masterindex + 1))
done

log_info "Stav clusteru po přidání masterů:"
kubectl get nodes

# ============================================================
# STEP 7: Přidání worker nodů
# ============================================================
log_step "Step 7/10: Přidávám worker nody..."

workerindex=1
for newnode in "${workers[@]}"; do
  nodename="worker${workerindex}"
  log_info "Joinuji worker node $newnode ($nodename)... (toto může trvat 2-5 minut)"
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
  log_info "Worker node $newnode přidán"
  workerindex=$((workerindex + 1))
done

log_info "Stav clusteru po přidání workerů:"
kubectl get nodes

# ============================================================
# STEP 8: MetalLB
# ============================================================
log_step "Step 8/10: Instaluji MetalLB..."

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Generuj MetalLB IPAddressPool (inline)
cat > $HOME/ipAddressPool.yaml <<POOL
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - $lbrange
POOL

# ============================================================
# STEP 9: MetalLB IP Pools + L2 Advertisement
# ============================================================
log_step "Step 9/10: Čekám na MetalLB controller a konfiguruji IP Pools..."
log_warn "Toto může trvat dlouho pokud se stahují container images..."

kubectl wait --namespace metallb-system \
                --for=condition=ready pod \
                --selector=component=controller \
                --timeout=1800s
kubectl apply -f ipAddressPool.yaml
# Generuj L2Advertisement (inline)
cat > $HOME/l2Advertisement.yaml <<L2ADV
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
L2ADV
kubectl apply -f $HOME/l2Advertisement.yaml
log_info "MetalLB nakonfigurován (IP range: $lbrange)"

# ============================================================
# STEP 10: Rancher + Cert-Manager + Helm
# ============================================================
log_step "Step 10/10: Instaluji Helm, Cert-Manager a Rancher..."

# Helm
if ! command -v helm &> /dev/null; then
    log_info "Instaluji Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh
else
    log_info "Helm již nainstalován"
fi

# Rancher Helm Repo
log_info "Přidávám Rancher Helm repo..."
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
kubectl create namespace cattle-system 2>/dev/null || true

# Cert-Manager
log_info "Instaluji Cert-Manager v1.13.2..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.crds.yaml
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.13.2

log_info "Čekám na Cert-Manager pods..."
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=300s

# Rancher
log_info "Instaluji Rancher (hostname: $rancherHostname)..."
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=$rancherHostname \
  --set bootstrapPassword=admin \
  --set ingress.tls.source=letsEncrypt \
  --set letsEncrypt.email=$letsencryptEmail

log_info "Čekám na Rancher deployment..."
kubectl -n cattle-system rollout status deploy/rancher --timeout=600s
kubectl -n cattle-system get deploy rancher

# Rancher LoadBalancer
log_info "Vytvářím Rancher LoadBalancer..."
kubectl expose deployment rancher --name=rancher-lb --port=443 --type=LoadBalancer -n cattle-system 2>/dev/null || true

log_info "Čekám na přiřazení LoadBalancer IP..."
while [[ -z $(kubectl get svc rancher-lb -n cattle-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]; do
  sleep 5
  echo -e "${YELLOW}  Čekám na MetalLB IP přiřazení...${NC}"
done

# ============================================================
# HOTOVO
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  INSTALACE DOKONČENA!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}Cluster nody:${NC}"
kubectl get nodes -o wide
echo ""
echo -e "${CYAN}Rancher services:${NC}"
kubectl get svc -n cattle-system
echo ""
RANCHER_IP=$(kubectl get svc rancher-lb -n cattle-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
echo -e "${GREEN}Rancher URL:  https://$rancherHostname${NC}"
echo -e "${GREEN}Rancher LB IP: $RANCHER_IP${NC}"
echo -e "${GREEN}Bootstrap heslo: admin${NC}"
echo -e "${YELLOW}Nezapomeň nastavit DNS: $rancherHostname -> $RANCHER_IP${NC}"
echo ""
