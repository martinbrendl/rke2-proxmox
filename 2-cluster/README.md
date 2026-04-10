# 2-cluster — RKE2 + Cilium CNI + Hubble UI

The second tier. Same HA architecture as 1-cluster, but with Cilium replacing Canal + MetalLB. eBPF networking, built-in load balancing, and live network traffic visualization via Hubble.

## What Gets Installed

| Component | Version | Purpose |
|-----------|---------|---------|
| RKE2 | stable | Kubernetes distribution |
| Kube-VIP | v0.8.7 | HA virtual IP for control plane |
| Cilium CNI | bundled with RKE2 | eBPF networking, replaces Canal + MetalLB |
| Cilium LB-IPAM | — | LoadBalancer IP pool (replaces MetalLB) |
| Cilium L2 Announcements | — | ARP for bare-metal LB (replaces MetalLB L2) |
| Hubble UI | bundled with Cilium | Live network traffic visualization |
| Rancher | latest | Cluster management UI |
| Cert-Manager | v1.13.2 | TLS certificates (Let's Encrypt) |

## What Changed vs 1-cluster

- **Canal → Cilium** — eBPF instead of iptables, faster routing, better observability
- **MetalLB removed** — Cilium LB-IPAM and L2 Announcements do the same in a single layer
- **kube-proxy disabled** — Cilium takes over all packet routing via eBPF
- **Hubble UI** — live view of network traffic between pods, accessible via LoadBalancer

## Key Detail: Bootstrap Order

During startup, Cilium needs to reach the API server. But Kube-VIP — which manages the VIP — only starts after Cilium runs, creating a circular dependency. The fix: `k8sServiceHost` points to the direct IP of master1, not the VIP.

```yaml
# HelmChartConfig — applied automatically at RKE2 startup
kubeProxyReplacement: true
k8sServiceHost: "10.0.0.211"   # master1 IP, not VIP (10.0.0.220)
k8sServicePort: 6443
```

## Usage

```bash
# Prerequisite: VM provisioning via Terraform (see ../terraform/)

# 1. Copy the script to the admin node
scp rke2-cilium.sh ubuntu@10.0.0.210:~/

# 2. Run installation (~15–25 min)
ssh ubuntu@10.0.0.210 'bash rke2-cilium.sh'
```

## Output After Completion

```
Rancher URL:     https://rancher.example.com
Rancher LB IP:   10.0.0.221
Hubble UI:       http://10.0.0.222
Bootstrap password: admin

Cilium LB-IPAM pool: 10.0.0.221 – 10.0.0.230   (15 available IPs)
```

## Configuration

Edit the variables at the top of `rke2-cilium.sh`:

```bash
admin=10.0.0.210
master1=10.0.0.211
# ...
vip=10.0.0.220
lbrangeStart=10.0.0.221
lbrangeStop=10.0.0.230
rancherHostname=rancher.example.com
letsencryptEmail=you@example.com
```

## Next Tiers

- Want to add GitOps and monitoring? → [3-cluster](../3-cluster/)
