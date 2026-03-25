############################################################
#  PROVIDER CONFIGURATION
#  Using bpg/proxmox - best maintained provider
############################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = true
    username = "root"
  }
}

############################################################
#  LOCAL VALUES
############################################################

locals {
  # Network mask for cloud-init (prefix /24)
  network_prefix = 24

  # Cloud-init user-data shared across all nodes
  cloud_init_user_data = <<-EOT
    #cloud-config
    package_update: true
    package_upgrade: false
    packages:
      - qemu-guest-agent
      - curl
      - wget
      - vim
      - net-tools
    runcmd:
      - systemctl enable qemu-guest-agent
      - systemctl start qemu-guest-agent
      - echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-k8s.conf
      - echo "net.bridge.bridge-nf-call-iptables=1" >> /etc/sysctl.d/99-k8s.conf
      - echo "net.bridge.bridge-nf-call-ip6tables=1" >> /etc/sysctl.d/99-k8s.conf
      - sysctl --system
      - swapoff -a
      - sed -i '/swap/d' /etc/fstab
    users:
      - name: ${var.vm_user}
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        ssh_authorized_keys:
          - ${var.ssh_public_key}
  EOT

  # Map of all nodes (for outputs)
  all_nodes = merge(
    { "admin" = var.admin_ip },
    { for i, ip in var.master_ips : "master${i + 1}" => ip },
    { for i, ip in var.worker_ips : "worker${i + 1}" => ip }
  )
}
