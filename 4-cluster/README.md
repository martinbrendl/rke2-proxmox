# 4-cluster — Sample Application (Community Tier)

The fourth tier. Builds on 3-cluster and adds a sample application deployed via the ArgoCD GitOps workflow — an end-to-end demonstration of the full stack in action.

## What Gets Installed

Everything from [3-cluster](../3-cluster/), plus:

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Pacman (or community choice) | `apps` | Sample app deployed via ArgoCD |

## How It Works

The sample application is stored as Kubernetes manifests in `apps/`. ArgoCD watches this folder in the repository and automatically deploys the application to the cluster — no manual `kubectl apply` needed.

```
apps/
└── pacman/
    ├── namespace.yaml
    ├── deployment.yaml
    └── service.yaml         # type: LoadBalancer → gets IP from Cilium LB-IPAM
```

## Usage

```bash
# Prerequisite: VM provisioning via Terraform (see ../terraform/)

# 1. Copy scripts to the admin node
scp rke2-cilium.sh ubuntu@10.0.0.210:~/
scp addons.sh ubuntu@10.0.0.210:~/

# 2. Run cluster installation
ssh ubuntu@10.0.0.210 'bash rke2-cilium.sh'

# 3. Install addons
ssh ubuntu@10.0.0.210 'bash addons.sh'

# 4. Add the app to ArgoCD
#    (manually via ArgoCD UI, or extend addons.sh to do it automatically)
```

## Output After Completion

```
Rancher URL:      https://rancher.example.com
Hubble UI:        http://10.0.0.222
Forgejo:          http://10.0.0.223
ArgoCD:           http://10.0.0.224
Grafana:          http://10.0.0.225
Pacman:           http://10.0.0.226
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
