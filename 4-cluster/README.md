# 4-cluster — Sample Application (Community Tier)

The fourth tier. Builds on 3-cluster and adds a sample application deployed via the ArgoCD GitOps workflow — an end-to-end demonstration of the full stack in action.

## What Gets Installed

Everything from [3-cluster](../3-cluster/), plus:

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Podinfo | `apps` | Sample app deployed via ArgoCD |

## How It Works

The sample application is stored as Kubernetes manifests in `apps/`. ArgoCD watches this folder in the repository and automatically deploys the application to the cluster — no manual `kubectl apply` needed.

```
apps/
└── podinfo/
    ├── namespace.yaml
    ├── deployment.yaml
    └── service.yaml         # type: LoadBalancer → gets IP from Cilium LB-IPAM
```

## Two Deployment Variants

This tier ships with **two** addon scripts — pick one (or run both in sequence):

| Script | Pattern | Description |
|--------|---------|-------------|
| `addons-podinfo.sh` | **Quickstart** — direct `kubectl apply` | Installs the 3-cluster stack (Forgejo + ArgoCD + Grafana + Prometheus) then applies the bundled `apps/podinfo/*.yaml` manifests directly. Fast, one-shot deployment. |
| `addons-podinfo-gitops.sh` | **Full GitOps** — Forgejo → ArgoCD | Assumes 3-cluster addons are already installed. Creates a private repo in Forgejo via API, pushes the podinfo manifests to it, registers it as an ArgoCD source using the internal cluster DNS, and creates an ArgoCD Application with auto-sync. Edits pushed to Forgejo auto-deploy to the cluster. |

## Usage

```bash
# Prerequisite: VM provisioning via Terraform (see ../terraform/)

# 1. Copy scripts + config to the admin node
scp ../config.env ubuntu@10.0.0.210:~/
scp rke2-cilium.sh longhorn.sh addons-podinfo.sh addons-podinfo-gitops.sh ubuntu@10.0.0.210:~/

# 2. Provision the cluster
ssh ubuntu@10.0.0.210 'bash rke2-cilium.sh'

# 3. Install Longhorn (persistent storage)
ssh ubuntu@10.0.0.210 'bash longhorn.sh'

# 4a. Quickstart variant — installs 3-cluster stack + direct kubectl apply of podinfo
ssh ubuntu@10.0.0.210 'bash addons-podinfo.sh'

# 4b. GitOps variant — run AFTER 3-cluster/addons.sh to wire podinfo through Forgejo + ArgoCD
ssh ubuntu@10.0.0.210 'bash addons-podinfo-gitops.sh'
```

### Testing the GitOps loop

Once `addons-podinfo-gitops.sh` finishes, any push to the Forgejo `podinfo` repo is auto-synced by ArgoCD within ~3 minutes:

```bash
git clone http://forgejo-admin@<FORGEJO_LB>:3000/forgejo-admin/podinfo.git
cd podinfo
# Edit apps/podinfo/deployment.yaml — e.g. change replicas: 2 → 3
git commit -am 'scale podinfo'
git push
# ArgoCD auto-syncs. Force immediately with:
kubectl -n argocd patch app podinfo --type merge \
  -p '{"operation":{"sync":{}}}'
```

## Output After Completion

```
Rancher URL:      https://rancher.example.com
Hubble UI:        http://10.0.0.222
Forgejo:          http://10.0.0.223
ArgoCD:           http://10.0.0.224
Grafana:          http://10.0.0.225
Podinfo:          http://10.0.0.226
```

## Want to Suggest a Different Sample App?

This tier is intentionally designed as a community tier — the application in `apps/` can change based on feedback. Leave a comment on LinkedIn or open a GitHub Issue.

Criteria for a good sample app:
- Simple Kubernetes manifests (Deployment + Service + optional Ingress)
- Shows something visually interesting (game, dashboard, demo UI)
- Demonstrates real Kubernetes concepts (persistent storage, scaling, networking)

## Ideas for 5-cluster?

- Vault for secrets management
- Velero for backup and disaster recovery
- Keycloak as identity provider for ArgoCD, Grafana and Forgejo
- Tekton or Forgejo Actions as a CI pipeline
