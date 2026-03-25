############################################################
#  OUTPUTS
############################################################

output "admin_node" {
  description = "Admin node IP address"
  value       = var.admin_ip
}

output "master_nodes" {
  description = "Master node IP addresses"
  value = {
    for i, ip in var.master_ips : "master${i + 1}" => ip
  }
}

output "worker_nodes" {
  description = "Worker node IP addresses"
  value = {
    for i, ip in var.worker_ips : "worker${i + 1}" => ip
  }
}

output "kube_vip" {
  description = "Virtual IP for kube-vip HA (configured after running RKE2 script)"
  value       = "10.0.0.220"
}

output "metallb_range" {
  description = "MetalLB LoadBalancer IP range"
  value       = "10.0.0.221 - 10.0.0.230"
}

output "rke2_script_command" {
  description = "Command to run RKE2 installation script after VM creation"
  value       = "ssh ubuntu@${var.admin_ip} 'bash ~/rke2-updated.sh'"
}

output "vm_ids" {
  description = "VM IDs of all created nodes"
  value = {
    admin   = proxmox_virtual_environment_vm.admin.vm_id
    masters = [for vm in proxmox_virtual_environment_vm.masters : vm.vm_id]
    workers = [for vm in proxmox_virtual_environment_vm.workers : vm.vm_id]
  }
}
