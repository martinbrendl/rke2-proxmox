# 3-cluster — GitOps + Observability Stack

The third tier. Builds on 2-cluster (Cilium + Hubble) and adds a complete GitOps workflow and monitoring stack.

## What Gets Installed

Everything from [2-cluster](../2-cluster/), plus:

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Forgejo | `forgejo` | Self-hosted Git (GitHub alternative) |
| ArgoCD | `argocd` | GitOps — automatic deployment from Git |
| Prometheus | `monitoring` | Cluster metrics collection |
| Grafana | `monitoring` | Dashboards and metrics visualization |

## GitOps Workflow

```
developer
   │
   ▼ git push
Forgejo (self-hosted Git)
   │
   ▼ ArgoCD watches the repo
ArgoCD
   │
   ▼ automatic deploy
Kubernetes cluster
```

After initial setup, no `kubectl apply` from a laptop is needed. The cluster always mirrors the state of the Git repository.

## Usage

```bash
# Prerequisite: VM provisioning via Terraform (see ../terraform/)

# 1. Copy scripts to the admin node
scp rke2-cilium.sh ubuntu@10.0.0.210:~/
scp addons.sh ubuntu@10.0.0.210:~/

# 2. Run cluster installation (~15–25 min)
ssh ubuntu@10.0.0.210 'bash rke2-cilium.sh'

# 3. Install addons (ArgoCD, Forgejo, monitoring stack)
ssh ubuntu@10.0.0.210 'bash addons.sh'
```

## Output After Completion

```
Rancher URL:      https://rancher.example.com
Hubble UI:        http://10.0.0.222
Forgejo:          http://10.0.0.223
ArgoCD:           http://10.0.0.224
Grafana:          http://10.0.0.225
```

> IP addresses depend on allocation order from the Cilium LB-IPAM pool (10.0.0.221–10.0.0.230).

## Configuration

```bash
# Edit at the top of addons.sh:
forgejo_admin_user=admin
forgejo_admin_password=changeme
argocd_admin_password=changeme
grafana_admin_password=changeme
```

## Next Tiers

- Want to add a sample app deployed via ArgoCD? → [4-cluster](../4-cluster/)
