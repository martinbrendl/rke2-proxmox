# RKE2 HA Cluster on Proxmox with Terraform

Fully automated deployment of a production-ready **RKE2 Kubernetes cluster** on Proxmox VE, including HA control plane, Kube-VIP, MetalLB, cert-manager, and Rancher.

## Architecture

```
                          ┌─────────────────┐
                          │   kube-vip VIP  │
                          │   10.0.0.220    │
                          └────────┬────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
      ┌───────┴───────┐   ┌───────┴───────┐   ┌───────┴───────┐
      │   master1     │   │   master2     │   │   master3     │
      │  10.0.0.211   │   │  10.0.0.212   │   │  10.0.0.213   │
      │  control-plane│   │  control-plane│   │  control-plane│
      │  etcd         │   │  etcd         │   │  etcd         │
      └───────────────┘   └───────────────┘   └───────────────┘
              ┌────────────────────┼────────────────────┐
      ┌───────┴───────┐                        ┌───────┴───────┐
      │   worker1     │                        │   worker2     │
      │  10.0.0.214   │                        │  10.0.0.215   │
      │  workloads    │                        │  workloads    │
      │  /dev/sdb 50G │                        │  /dev/sdb 50G │
      │  (Longhorn)   │                        │  (Longhorn)   │
      └───────────────┘                        └───────────────┘

      ┌───────────────┐       MetalLB LB Range:
      │   admin       │       10.0.0.221 - 10.0.0.230
      │  10.0.0.210   │
      │  orchestrator │
      └───────────────┘
```

## Components

| Component | Purpose | Version |
|-----------|---------|---------|
| **Proxmox VE** | Hypervisor | 8.x |
| **Terraform** (bpg/proxmox) | VM provisioning via IaC | >= 0.66.0 |
| **RKE2** | Kubernetes distribution (FIPS-compliant) | v1.34.x |
| **Kube-VIP** | HA virtual IP for control plane | v0.8.7 |
| **MetalLB** | Bare-metal LoadBalancer | v0.13.12 |
| **cert-manager** | Automated TLS certificate management | v1.13.2 |
| **Rancher** | Kubernetes management UI | latest |
| **Longhorn** | Distributed block storage for Kubernetes | v1.7.2 |

## Prerequisites

- Proxmox VE 8.x with an Ubuntu 24.04 cloud-init template (VM ID 9000)
- Terraform >= 1.5.0
- SSH key pair (ed25519 recommended)
- Proxmox API token with VM creation permissions

## Quick Start

### 1. Provision VMs with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values (Proxmox endpoint, API token, SSH key, IPs)
terraform init
terraform apply
```

### 2. Deploy RKE2 Cluster

```bash
# Copy SSH keys and installer to admin node
scp ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub ubuntu@10.0.0.210:~/
scp rke2.sh ubuntu@10.0.0.210:~/

# Run the installer
ssh ubuntu@10.0.0.210 'bash rke2.sh'
```

The script will automatically:
1. Install and configure RKE2 on master1 with kube-vip static pod
2. Wait for master1 to reach `Ready` state
3. Join master2 and master3 to form HA etcd cluster
4. Join worker nodes
5. Deploy Kube-VIP cloud provider
6. Deploy MetalLB with L2 advertisement
7. Install Helm, cert-manager, and Rancher with Let's Encrypt TLS

### 3. Install Longhorn Storage

```bash
scp longhorn.sh ubuntu@10.0.0.210:~/
ssh ubuntu@10.0.0.210 'bash longhorn.sh'
```

The script will automatically:
1. Verify worker nodes have the `longhorn=true` label
2. Install storage dependencies (open-iscsi, nfs-common) on workers
3. Format and mount the extra 50GB disk (`/dev/sdb`) on each worker at `/var/lib/longhorn`
4. Install Longhorn via Helm, pinned to worker nodes only
5. Verify all Longhorn pods are running

### 4. Access Rancher

Set up DNS: `rancher.example.com -> <MetalLB IP>` and open `https://rancher.example.com`.

## Cleanup

To tear down the RKE2 cluster without destroying VMs:

```bash
scp cleanup-rke2.sh ubuntu@10.0.0.210:~/
ssh ubuntu@10.0.0.210 'bash cleanup-rke2.sh'
```

To destroy everything:

```bash
cd terraform
terraform destroy
```

## File Structure

```
.
├── rke2.sh                          # Main RKE2 cluster installer
├── longhorn.sh                      # Longhorn storage installer (extra disk)
├── cleanup-rke2.sh                  # Cluster cleanup script
├── terraform/
│   ├── main.tf                      # Provider config + cloud-init
│   ├── vms.tf                       # VM resources (admin, masters, workers)
│   ├── variables.tf                 # Variable definitions
│   ├── outputs.tf                   # Output definitions
│   └── terraform.tfvars.example     # Example configuration
└── README.md
```

## Key Design Decisions

- **Unique node names**: Each node gets a distinct `node-name` in RKE2 config to prevent etcd join conflicts (common pitfall with identical cloud-init hostnames).
- **Readiness gates**: The script waits for master1 to reach `Ready` status (not just port 9345) before joining additional masters, preventing etcd bootstrap race conditions.
- **Systemd timeout override**: `TimeoutStartSec=600` for RKE2 services since initial cluster join can take several minutes (image pulls, etcd sync).
- **Inline manifests**: Kube-VIP, MetalLB IPAddressPool, and L2Advertisement are generated inline - no external template dependencies.
- **Idempotent configuration**: Config files are truncated (not appended), PATH entries are guarded against duplication, and previous installations are cleaned before re-joining.
- **Dedicated storage disks**: Workers get a separate 50GB disk (`/dev/sdb`) provisioned by Terraform, formatted and mounted by `longhorn.sh`. Longhorn is pinned to workers only via `nodeSelector` (`--set-string` to avoid Helm bool/string coercion).

## Configuration

Edit the variables section at the top of `rke2.sh`:

| Variable | Description | Default |
|----------|-------------|---------|
| `admin` | Admin node IP | 10.0.0.210 |
| `master1-3` | Control plane IPs | 10.0.0.211-213 |
| `worker1-2` | Worker IPs | 10.0.0.214-215 |
| `vip` | Kube-VIP virtual IP | 10.0.0.220 |
| `lbrange` | MetalLB IP range | 10.0.0.221-230 |
| `certName` | SSH key filename | id_ed25519 |
| `rancherHostname` | Rancher FQDN | rancher.example.com |
| `letsencryptEmail` | Let's Encrypt email | admin@example.com |

`longhorn.sh` variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `worker1-2` | Worker node IPs | 10.0.0.214-215 |
| `longhorn_disk` | Extra disk device | /dev/sdb |
| `longhorn_path` | Mount point for storage | /var/lib/longhorn |
| `longhorn_version` | Longhorn Helm chart version | 1.7.2 |

## License

MIT
