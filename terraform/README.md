# terraform/

Proxmox VM provisioning for the RKE2 cluster. Uses the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest) Terraform provider to create all nodes from a cloud-init template.

## What it creates

| VM | Default IP | CPU | RAM | Disk | Purpose |
|----|-----------|-----|-----|------|---------|
| rke2-admin | 10.0.0.210 | 2 | 2 GB | 20 GB | Runs installation scripts |
| rke2-master1 | 10.0.0.211 | 4 | 8 GB | 50 GB | Control-plane + etcd |
| rke2-master2 | 10.0.0.212 | 4 | 8 GB | 50 GB | Control-plane + etcd |
| rke2-master3 | 10.0.0.213 | 4 | 8 GB | 50 GB | Control-plane + etcd |
| rke2-worker1 | 10.0.0.214 | 4 | 8 GB | 100 GB + 50 GB | Worker + Longhorn storage |
| rke2-worker2 | 10.0.0.215 | 4 | 8 GB | 100 GB + 50 GB | Worker + Longhorn storage |

Worker nodes get an extra 50 GB disk (`/dev/sdb`) for Longhorn persistent storage.

## Prerequisites

- Proxmox VE 8.x with API access
- Ubuntu 24.04 cloud-init template (VM ID 9000)
- Terraform >= 1.5
- SSH key pair (`id_ed25519`)
- Proxmox API token with VM creation permissions

### Creating the cloud-init template

```bash
# On your Proxmox host
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qm create 9000 --name ubuntu-2404-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-single --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
qm template 9000
```

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Proxmox credentials and network settings
terraform init
terraform plan
terraform apply
```

## Configuration

All settings are in `terraform.tfvars`. Copy from `terraform.tfvars.example` and adjust:

| Variable | Description | Default |
|----------|-------------|---------|
| `proxmox_endpoint` | Proxmox API URL | — |
| `proxmox_api_token` | API token | — |
| `ssh_public_key` | SSH public key content | — |
| `proxmox_node` | Proxmox node name | `pve` |
| `template_id` | Cloud-init template VM ID | `9000` |
| `admin_ip` | Admin node IP | `10.0.0.210` |
| `master_ips` | Master node IPs (3 for HA) | `[10.0.0.211-213]` |
| `worker_ips` | Worker node IPs | `[10.0.0.214-215]` |
| `vm_id_offset` | Starting VM ID | `8000` |

## Files

```
terraform/
├── main.tf                  # Provider config + cloud-init user-data
├── vms.tf                   # VM resources (admin, masters, workers)
├── variables.tf             # All input variables with defaults
├── outputs.tf               # Node IP outputs
└── terraform.tfvars.example # Example configuration
```

## Cleanup

```bash
terraform destroy
```
