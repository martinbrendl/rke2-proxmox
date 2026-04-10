############################################################
#  OUTPUTS
############################################################

output "admin_node" {
  description = "IP adresa admin nodu"
  value       = var.admin_ip
}

output "master_nodes" {
  description = "IP adresy master nodů"
  value = {
    for i, ip in var.master_ips : "master${i + 1}" => ip
  }
}

output "worker_nodes" {
  description = "IP adresy worker nodů"
  value = {
    for i, ip in var.worker_ips : "worker${i + 1}" => ip
  }
}

output "kube_vip" {
  description = "Virtual IP pro kube-vip HA (nastaví se až po spuštění RKE2 skriptu)"
  value       = "10.0.0.220"
}

output "metallb_range" {
  description = "MetalLB LoadBalancer IP rozsah"
  value       = "10.0.0.221 - 10.0.0.230"
}

output "rke2_script_command" {
  description = "Příkaz pro spuštění RKE2 instalačního skriptu po vytvoření VM"
  value       = "ssh ubuntu@${var.admin_ip} 'bash ~/rke2-updated.sh'"
}

output "vm_ids" {
  description = "VM ID všech vytvořených nodů"
  value = {
    admin   = proxmox_virtual_environment_vm.admin.vm_id
    masters = [for vm in proxmox_virtual_environment_vm.masters : vm.vm_id]
    workers = [for vm in proxmox_virtual_environment_vm.workers : vm.vm_id]
  }
}
