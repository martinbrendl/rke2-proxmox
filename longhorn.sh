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
echo '  ║        Longhorn Storage Installer                 ║'
echo '  ║   RKE2 + Proxmox + Extra Disk (/dev/sdb)         ║'
echo '  ║   github.com/martinbrendl/rke2-proxmox            ║'
echo '  ╚═══════════════════════════════════════════════════╝'
echo -e "${NC}"

#############################################
# YOU SHOULD ONLY NEED TO EDIT THIS SECTION #
#############################################

# Worker nodes (must already be joined to cluster)
worker1=10.0.0.214
worker2=10.0.0.215

# SSH user on remote machines
user=ubuntu

# SSH key filename
certName=id_ed25519

# Extra disk for Longhorn (added by Terraform as scsi1)
longhorn_disk=/dev/sdb

# Mount point for Longhorn data
longhorn_path=/var/lib/longhorn

# Longhorn version
longhorn_version=1.7.2

#############################################
#            DO NOT EDIT BELOW              #
#############################################

workers=($worker1 $worker2)

# ============================================================
# STEP 1: Verify prerequisites
# ============================================================
log_step "Step 1/5: Verifying prerequisites..."

# Kubectl must be available and cluster must be running
if ! kubectl get nodes &>/dev/null; then
  log_error "kubectl not working - not on admin node or cluster is not running"
  exit 1
fi

log_info "Current cluster state:"
kubectl get nodes -o wide

# Verify worker nodes have longhorn=true label
for node in worker1 worker2; do
  label=$(kubectl get node $node --show-labels 2>/dev/null | grep -c "longhorn=true" || true)
  if [ "$label" -eq 0 ]; then
    log_warn "Node $node missing longhorn=true label, adding..."
    kubectl label node $node longhorn=true --overwrite
  else
    log_info "Node $node has longhorn=true label ✓"
  fi
done

# ============================================================
# STEP 2: Install dependencies on worker nodes
# ============================================================
log_step "Step 2/5: Installing dependencies on worker nodes (open-iscsi, nfs-common)..."

for newnode in "${workers[@]}"; do
  log_info "  -> $newnode"
  ssh -i ~/.ssh/$certName $user@$newnode "sudo bash" <<EOF
export DEBIAN_FRONTEND=noninteractive
apt-get install -y open-iscsi nfs-common cryptsetup dmsetup 2>/dev/null
systemctl enable --now iscsid
EOF
done
log_info "Dependencies installed"

# ============================================================
# STEP 3: Prepare extra disk on worker nodes
# ============================================================
log_step "Step 3/5: Preparing extra disk ($longhorn_disk) on worker nodes..."

for newnode in "${workers[@]}"; do
  log_info "  -> $newnode: formatting and mounting $longhorn_disk"
  ssh -i ~/.ssh/$certName $user@$newnode "sudo bash" <<EOF
set -e

DISK="$longhorn_disk"
MOUNT="$longhorn_path"

# Check if disk exists
if [ ! -b "\$DISK" ]; then
  echo "WARN: Disk \$DISK not found on \$(hostname), skipping"
  exit 0
fi

# If disk is empty (no partition table), format it
if ! blkid "\$DISK" &>/dev/null; then
  echo "Formatting \$DISK as ext4..."
  mkfs.ext4 -F "\$DISK"
fi

# Create mount point
mkdir -p "\$MOUNT"

# Add to fstab if not already present
DISK_UUID=\$(blkid -s UUID -o value "\$DISK")
if ! grep -q "\$DISK_UUID" /etc/fstab 2>/dev/null; then
  echo "UUID=\$DISK_UUID \$MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
  echo "Added to /etc/fstab: UUID=\$DISK_UUID"
fi

# Mount disk if not already mounted
if ! mountpoint -q "\$MOUNT"; then
  mount "\$MOUNT"
  echo "Disk mounted at \$MOUNT"
else
  echo "Disk already mounted at \$MOUNT"
fi

echo "Disk \$DISK is ready:"
df -h "\$MOUNT"
EOF
done
log_info "Extra disks ready"

# ============================================================
# STEP 4: Install Longhorn via Helm
# ============================================================
log_step "Step 4/5: Installing Longhorn v${longhorn_version} via Helm..."

# Add Longhorn Helm repo
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update

# Create namespace
kubectl create namespace longhorn-system 2>/dev/null || true

# Clean up previous attempt (for idempotent re-run)
helm uninstall longhorn --namespace longhorn-system 2>/dev/null || true

# Install Longhorn - pinned to nodes with longhorn=true label
# NOTE: --set-string is required, otherwise Helm interprets "true" as boolean
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "${longhorn_version}" \
  --set defaultSettings.defaultDataPath="$longhorn_path" \
  --set-string longhornManager.nodeSelector."longhorn"="true" \
  --set-string longhornDriver.nodeSelector."longhorn"="true" \
  --set-string longhornUI.nodeSelector."longhorn"="true" \
  --wait \
  --timeout 10m

log_info "Longhorn installed"

# ============================================================
# STEP 5: Verify installation
# ============================================================
log_step "Step 5/5: Verifying Longhorn installation..."

log_info "Waiting for Longhorn pods..."
kubectl wait --namespace longhorn-system \
  --for=condition=ready pod \
  --selector=app=longhorn-manager \
  --timeout=300s

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  LONGHORN INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}Cluster nodes:${NC}"
kubectl get nodes -o wide
echo ""
echo -e "${CYAN}Longhorn pods:${NC}"
kubectl get pods -n longhorn-system
echo ""
echo -e "${CYAN}Longhorn storage classes:${NC}"
kubectl get storageclass
echo ""
echo -e "${GREEN}Longhorn UI: available via Rancher -> Cluster -> Storage -> Longhorn${NC}"
echo -e "${YELLOW}Or set up port-forward: kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80${NC}"
echo ""
