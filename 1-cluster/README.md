# 1-cluster — RKE2 HA Cluster (baseline)

The baseline tier. A fully functional HA Kubernetes cluster with distributed storage and Rancher.

## What Gets Installed

| Component | Version | Purpose |
|-----------|---------|---------|
| RKE2 | stable | Kubernetes distribution |
| Kube-VIP | v0.8.7 | HA virtual IP for control plane |
| MetalLB | v0.13.12 | LoadBalancer for bare-metal |
| Longhorn | v1.7.2 | Distributed block storage |
| Rancher | latest | Cluster management UI |
| Cert-Manager | v1.13.2 | TLS certificates (Let's Encrypt) |

## Topology

```
                    ┌─────────────────────────────┐
                    │  Kube-VIP  10.0.0.220        │
                    │  (HA control plane endpoint) │
                    └──────────┬──────────────────┘
              ┌────────────────┼────────────────┐
        master1             master2           master3
      10.0.0.211          10.0.0.212        10.0.0.213
    (etcd + cp)         (etcd + cp)       (etcd + cp)

        worker1                           worker2
      10.0.0.214                        10.0.0.215
   (Longhorn disk)                   (Longhorn disk)

   MetalLB pool: 10.0.0.221 – 10.0.0.230
```

## Usage

```bash
# Prerequisite: VM provisioning via Terraform (see ../terraform/)

# 1. Copy scripts to the admin node
scp rke2.sh ubuntu@10.0.0.210:~/
scp longhorn.sh ubuntu@10.0.0.210:~/

# 2. Run cluster installation (~15–25 min)
ssh ubuntu@10.0.0.210 'bash rke2.sh'

# 3. After completion — install Longhorn (optional)
ssh ubuntu@10.0.0.210 'bash longhorn.sh'
```

## What the Script Does

`rke2.sh` runs through these steps:

1. Time sync, kubectl installation
2. SSH key distribution to all nodes
3. Kube-VIP manifest and RKE2 config preparation
4. RKE2 installation on master1, waiting for Ready state
5. kubectl configuration on the admin node
6. Kube-VIP Cloud Provider installation
7. master2 and master3 join the cluster
8. worker1 and worker2 join the cluster
9. MetalLB configuration (IP pool + L2 advertisement)
10. Helm, Cert-Manager and Rancher installation

## Output After Completion

```
Rancher URL:   https://rancher.example.com
Rancher LB IP: 10.0.0.221
Bootstrap password: admin
```

## Configuration

Edit the variables at the top of `rke2.sh`:

```bash
admin=10.0.0.210
master1=10.0.0.211
# ...
vip=10.0.0.220
lbrange=10.0.0.221-10.0.0.230
rancherHostname=rancher.example.com
letsencryptEmail=you@example.com
```

## Next Tiers

- Want modern eBPF networking? → [2-cluster](../2-cluster/) (Cilium CNI + Hubble)
- Want to jump straight to the GitOps stack? → [3-cluster](../3-cluster/)
