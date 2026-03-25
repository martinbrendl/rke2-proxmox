############################################################
#  ADMIN NODE (10.0.0.210)
############################################################

resource "proxmox_virtual_environment_vm" "admin" {
  name        = "rke2-admin"
  description = "RKE2 Admin node - runs installation scripts"
  tags        = ["rke2", "admin", "kubernetes"]

  node_name = var.proxmox_node
  vm_id     = var.vm_id_offset

  clone {
    vm_id   = var.template_id
    full    = true
    retries = 3
  }

  agent {
    enabled = true
    timeout = "15m"
  }

  cpu {
    cores   = var.admin_cpu
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = var.admin_memory
  }

  # virtio-scsi-single is required for iothread
  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.admin_disk_size
    discard      = "on"
    iothread     = true
    file_format  = "raw"
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.vlan_id > 0 ? var.vlan_id : null
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.admin_ip}/${local.network_prefix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = [var.dns_server]
      domain  = var.dns_domain
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_admin.id
  }

  lifecycle {
    ignore_changes = [clone, initialization]
  }

  depends_on = [proxmox_virtual_environment_file.cloud_init_admin]
}

resource "proxmox_virtual_environment_file" "cloud_init_admin" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = local.cloud_init_user_data
    file_name = "rke2-admin-cloud-init.yaml"
  }
}

############################################################
#  MASTER NODES (10.0.0.211-213)
############################################################

resource "proxmox_virtual_environment_vm" "masters" {
  count = length(var.master_ips)

  name        = "rke2-master${count.index + 1}"
  description = "RKE2 Control-plane node ${count.index + 1}"
  tags        = ["rke2", "master", "control-plane", "kubernetes"]

  node_name = var.proxmox_node
  vm_id     = var.vm_id_offset + count.index + 1

  clone {
    vm_id   = var.template_id
    full    = true
    retries = 3
  }

  agent {
    enabled = true
    timeout = "15m"
  }

  cpu {
    cores   = var.master_cpu
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = var.master_memory
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.master_disk_size
    discard      = "on"
    iothread     = true
    file_format  = "raw"
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.vlan_id > 0 ? var.vlan_id : null
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.master_ips[count.index]}/${local.network_prefix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = [var.dns_server]
      domain  = var.dns_domain
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_masters[count.index].id
  }

  lifecycle {
    ignore_changes = [clone, initialization]
  }

  depends_on = [proxmox_virtual_environment_file.cloud_init_masters]
}

resource "proxmox_virtual_environment_file" "cloud_init_masters" {
  count = length(var.master_ips)

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = local.cloud_init_user_data
    file_name = "rke2-master${count.index + 1}-cloud-init.yaml"
  }
}

############################################################
#  WORKER NODES (10.0.0.214-215)
############################################################

resource "proxmox_virtual_environment_vm" "workers" {
  count = length(var.worker_ips)

  name        = "rke2-worker${count.index + 1}"
  description = "RKE2 Worker node ${count.index + 1}"
  tags        = ["rke2", "worker", "kubernetes"]

  node_name = var.proxmox_node
  vm_id     = var.vm_id_offset + length(var.master_ips) + count.index + 1

  clone {
    vm_id   = var.template_id
    full    = true
    retries = 3
  }

  agent {
    enabled = true
    timeout = "15m"
  }

  cpu {
    cores   = var.worker_cpu
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = var.worker_memory
  }

  scsi_hardware = "virtio-scsi-single"

  # OS disk
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.worker_disk_size
    discard      = "on"
    iothread     = true
    file_format  = "raw"
  }

  # Extra disk for Longhorn storage
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi1"
    size         = 50
    discard      = "on"
    iothread     = true
    file_format  = "raw"
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.vlan_id > 0 ? var.vlan_id : null
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.worker_ips[count.index]}/${local.network_prefix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = [var.dns_server]
      domain  = var.dns_domain
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_workers[count.index].id
  }

  lifecycle {
    ignore_changes = [clone, initialization]
  }

  depends_on = [proxmox_virtual_environment_file.cloud_init_workers]
}

resource "proxmox_virtual_environment_file" "cloud_init_workers" {
  count = length(var.worker_ips)

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = local.cloud_init_user_data
    file_name = "rke2-worker${count.index + 1}-cloud-init.yaml"
  }
}
