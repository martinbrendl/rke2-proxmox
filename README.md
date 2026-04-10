# rke2-proxmox

Self-hosted HA Kubernetes cluster on Proxmox. VM provisioning via Terraform, full installation with a single script.

The project is structured into tiers — each builds on the previous one. Pick the complexity level that matches what you want to build or learn.

## Architecture

```
Proxmox Host
├── rke2-admin    (10.0.0.210)  — runs the installation script
├── rke2-master1  (10.0.0.211)  — control-plane + etcd
├── rke2-master2  (10.0.0.212)  — control-plane + etcd
├── rke2-master3  (10.0.0.213)  — control-plane + etcd
├── rke2-worker1  (10.0.0.214)  — worker + Longhorn storage
└── rke2-worker2  (10.0.0.215)  — worker + Longhorn storage

Kube-VIP:  10.0.0.220            — HA virtual IP for control plane
LB pool:   10.0.0.221–10.0.0.230 — LoadBalancer IPs for services
```

## Tiers

| Tier | Contents | Scripts |
|------|----------|---------|
| [1-cluster](./1-cluster/) | RKE2 + Kube-VIP + MetalLB + Longhorn + Rancher | `rke2.sh` + `longhorn.sh` |
| [2-cluster](./2-cluster/) | RKE2 + Kube-VIP + Cilium CNI + Hubble UI + Rancher | `rke2-cilium.sh` + `longhorn.sh` |
| [3-cluster](./3-cluster/) | 2-cluster + ArgoCD + Forgejo + Prometheus + Grafana | `rke2-cilium.sh` + `longhorn.sh` + `addons.sh` |
| [4-cluster](./4-cluster/) | 3-cluster + Podinfo sample app | `rke2-cilium.sh` + `longhorn.sh` + `addons-podinfo.sh` + `apps/` |

## Prerequisites (all tiers)

- Proxmox VE 8.x
- Ubuntu 24.04 cloud-init template (VM ID 9000) — see [terraform/README.md](./terraform/README.md)
- Terraform >= 1.5
- SSH key (`id_ed25519`) for node access

## Quick Start

```bash
# 1. Provision VMs on Proxmox
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init && terraform apply

# 2. Create your local config (gitignored)
cd ..
cp config.env.example config.env
# edit config.env with your IPs, hostname, email, passwords

# 3. Copy the chosen tier script + config.env to the admin node and run it
scp config.env 1-cluster/rke2.sh ubuntu@10.0.0.210:~/
ssh ubuntu@10.0.0.210 'bash rke2.sh'
```

## Configuration — `config.env`

All scripts read their settings from a shared `config.env` file that is **gitignored**,
so you can keep your real IPs, hostnames and passwords out of version control.

```bash
cp config.env.example config.env
vim config.env
```

Each script looks for `config.env` in this order and uses the first match:

1. Same directory as the script
2. One directory up (repo root)
3. `$HOME/config.env` on the admin node

If no `config.env` is found, the defaults hard-coded at the top of each script are used.
This makes the public repo fully self-contained while still letting you run the exact
same scripts against your real cluster.

## Terraform — VM Provisioning

All tiers share the same Terraform configuration in [`terraform/`](./terraform/). It provisions 6 Ubuntu 24.04 VMs on Proxmox via the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest) provider: 1 admin, 3 masters, 2 workers (with an extra disk for Longhorn storage).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit with your Proxmox credentials
terraform init && terraform apply
```

See [terraform/README.md](./terraform/README.md) for full setup instructions including cloud-init template creation.

## Repository Structure

```
rke2-proxmox/
├── config.env.example      # Template for local config (copy to config.env)
├── .gitignore              # Excludes config.env, terraform.tfvars, state, keys
├── terraform/              # Proxmox VM provisioning (shared across all tiers)
│   ├── main.tf             # Provider config + cloud-init
│   ├── vms.tf              # VM resources (admin, masters, workers)
│   ├── variables.tf        # Input variables
│   ├── outputs.tf          # Node IP outputs
│   └── terraform.tfvars.example
├── 1-cluster/              # Basic HA cluster (MetalLB + Longhorn + Rancher)
│   ├── rke2.sh
│   └── longhorn.sh
├── 2-cluster/              # Cilium CNI + Hubble UI
│   ├── rke2-cilium.sh
│   └── longhorn.sh
├── 3-cluster/              # GitOps + observability stack
│   ├── rke2-cilium.sh
│   ├── longhorn.sh
│   └── addons.sh
└── 4-cluster/              # + Podinfo sample application
    ├── rke2-cilium.sh
    ├── longhorn.sh
    ├── addons-podinfo.sh
    └── apps/podinfo/       # Kubernetes manifests
```

## License

MIT
