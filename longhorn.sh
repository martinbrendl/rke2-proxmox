#!/bin/bash

# Barvy pro výstup
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
echo '  ║        Longhorn Storage Installer                 ║'
echo '  ║   RKE2 + Proxmox + Extra Disk (/dev/sdb)         ║'
echo '  ║   github.com/martinbrendl/rke2-proxmox            ║'
echo '  ╚═══════════════════════════════════════════════════╝'
echo -e "${NC}"

#############################################
# YOU SHOULD ONLY NEED TO EDIT THIS SECTION #
#############################################

# Worker nody (musí být již v clusteru)
worker1=10.0.0.214
worker2=10.0.0.215

# Uživatel na vzdálených strojích
user=ubuntu

# SSH klíč
certName=id_ed25519

# Extra disk pro Longhorn (přidán Terraformem jako scsi1)
longhorn_disk=/dev/sdb

# Mount point pro Longhorn data
longhorn_path=/var/lib/longhorn

# Longhorn verze
longhorn_version=1.7.2

#############################################
#            DO NOT EDIT BELOW              #
#############################################

workers=($worker1 $worker2)

# ============================================================
# STEP 1: Ověření prerekvizit
# ============================================================
log_step "Step 1/5: Ověřuji prerekvizity..."

# Kubectl musí být dostupný a cluster musí běžet
if ! kubectl get nodes &>/dev/null; then
  log_error "kubectl nefunguje - nejsi na admin nodu nebo cluster neběží"
  exit 1
fi

log_info "Aktuální stav clusteru:"
kubectl get nodes -o wide

# Ověř že worker nody mají label longhorn=true
for node in worker1 worker2; do
  label=$(kubectl get node $node --show-labels 2>/dev/null | grep -c "longhorn=true" || true)
  if [ "$label" -eq 0 ]; then
    log_warn "Node $node nemá label longhorn=true, přidávám..."
    kubectl label node $node longhorn=true --overwrite
  else
    log_info "Node $node má label longhorn=true ✓"
  fi
done

# ============================================================
# STEP 2: Instalace závislostí na worker nodech
# ============================================================
log_step "Step 2/5: Instaluji závislosti na worker nodech (open-iscsi, nfs-common)..."

for newnode in "${workers[@]}"; do
  log_info "  -> $newnode"
  ssh -i ~/.ssh/$certName $user@$newnode "sudo bash" <<EOF
export DEBIAN_FRONTEND=noninteractive
apt-get install -y open-iscsi nfs-common cryptsetup dmsetup 2>/dev/null
systemctl enable --now iscsid
EOF
done
log_info "Závislosti nainstalovány"

# ============================================================
# STEP 3: Příprava extra disku na worker nodech
# ============================================================
log_step "Step 3/5: Připravuji extra disk ($longhorn_disk) na worker nodech..."

for newnode in "${workers[@]}"; do
  log_info "  -> $newnode: formátuji a připojuji $longhorn_disk"
  ssh -i ~/.ssh/$certName $user@$newnode "sudo bash" <<EOF
set -e

DISK="$longhorn_disk"
MOUNT="$longhorn_path"

# Zkontroluj zda disk existuje
if [ ! -b "\$DISK" ]; then
  echo "WARN: Disk \$DISK nenalezen na \$(hostname), přeskakuji"
  exit 0
fi

# Pokud je disk prázdný (bez partition table), naformátuj ho
if ! blkid "\$DISK" &>/dev/null; then
  echo "Formátuji \$DISK jako ext4..."
  mkfs.ext4 -F "\$DISK"
fi

# Vytvoř mount point
mkdir -p "\$MOUNT"

# Přidej do fstab pokud tam ještě není
DISK_UUID=\$(blkid -s UUID -o value "\$DISK")
if ! grep -q "\$DISK_UUID" /etc/fstab 2>/dev/null; then
  echo "UUID=\$DISK_UUID \$MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
  echo "Přidáno do /etc/fstab: UUID=\$DISK_UUID"
fi

# Připoj disk pokud není připojen
if ! mountpoint -q "\$MOUNT"; then
  mount "\$MOUNT"
  echo "Disk připojen na \$MOUNT"
else
  echo "Disk je již připojen na \$MOUNT"
fi

echo "Disk \$DISK je připraven:"
df -h "\$MOUNT"
EOF
done
log_info "Extra disky připraveny"

# ============================================================
# STEP 4: Instalace Longhorn přes Helm
# ============================================================
log_step "Step 4/5: Instaluji Longhorn v${longhorn_version} přes Helm..."

# Přidej Longhorn Helm repo
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update

# Vytvoř namespace
kubectl create namespace longhorn-system 2>/dev/null || true

# Vyčisti předchozí pokus (pro idempotentní re-run)
helm uninstall longhorn --namespace longhorn-system 2>/dev/null || true

# Instaluj Longhorn - pin na nody s labelem longhorn=true
# POZOR: --set-string je nutné, jinak Helm interpretuje "true" jako boolean
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "${longhorn_version}" \
  --set defaultSettings.defaultDataPath="$longhorn_path" \
  --set-string longhornManager.nodeSelector."longhorn"="true" \
  --set-string longhornDriver.nodeSelector."longhorn"="true" \
  --set-string longhornUI.nodeSelector."longhorn"="true" \
  --wait \
  --timeout 10m

log_info "Longhorn nainstalován"

# ============================================================
# STEP 5: Ověření + výpis
# ============================================================
log_step "Step 5/5: Ověřuji instalaci Longhorn..."

log_info "Čekám na Longhorn pods..."
kubectl wait --namespace longhorn-system \
  --for=condition=ready pod \
  --selector=app=longhorn-manager \
  --timeout=300s

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  LONGHORN INSTALACE DOKONČENA!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}Cluster nody:${NC}"
kubectl get nodes -o wide
echo ""
echo -e "${CYAN}Longhorn pods:${NC}"
kubectl get pods -n longhorn-system
echo ""
echo -e "${CYAN}Longhorn storage classes:${NC}"
kubectl get storageclass
echo ""
echo -e "${GREEN}Longhorn UI: dostupné přes Rancher -> Cluster -> Storage -> Longhorn${NC}"
echo -e "${YELLOW}Nebo nastav port-forward: kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80${NC}"
echo ""
