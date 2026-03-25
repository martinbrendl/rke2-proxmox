############################################################
#  VARIABLES - edit terraform.tfvars                      #
############################################################

variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://10.0.0.1:8006"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox user in format user@realm, e.g. terraform@pve"
  type        = string
  default     = "terraform@pve"
}

variable "proxmox_api_token" {
  description = "API token in format terraform@pve!mytoken=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name where VMs will be created"
  type        = string
  default     = "pve"
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification (self-signed cert)"
  type        = bool
  default     = true
}

# ----------------------------------------------------------
# Template / Cloud-Init
# ----------------------------------------------------------

variable "template_id" {
  description = "Template VM ID (Ubuntu cloud-init template)"
  type        = number
  default     = 9000
}

variable "datastore_id" {
  description = "Proxmox datastore for VM disks (local-lvm, ceph, etc.)"
  type        = string
  default     = "local-lvm"
}

variable "iso_datastore_id" {
  description = "Proxmox datastore for cloud-init ISO"
  type        = string
  default     = "local"
}

# ----------------------------------------------------------
# Network configuration
# ----------------------------------------------------------

variable "network_gateway" {
  description = "Default network gateway"
  type        = string
  default     = "10.0.0.1"
}

variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag (0 = no VLAN)"
  type        = number
  default     = 0
}

variable "dns_server" {
  description = "DNS server pro VM"
  type        = string
  default     = "8.8.8.8"
}

variable "dns_domain" {
  description = "DNS domain suffix"
  type        = string
  default     = "local"
}

# ----------------------------------------------------------
# SSH key for cloud-init
# ----------------------------------------------------------

variable "ssh_public_key" {
  description = "SSH public key content for ubuntu user"
  type        = string
}

variable "vm_user" {
  description = "VM user (must match the script)"
  type        = string
  default     = "ubuntu"
}

# ----------------------------------------------------------
# Admin node configuration
# ----------------------------------------------------------

variable "admin_ip" {
  description = "Admin node IP address"
  type        = string
  default     = "10.0.0.210"
}

variable "admin_cpu" {
  type    = number
  default = 2
}

variable "admin_memory" {
  description = "RAM in MB"
  type        = number
  default     = 2048
}

variable "admin_disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 20
}

# ----------------------------------------------------------
# Master nodes configuration
# ----------------------------------------------------------

variable "master_ips" {
  description = "Master node IP addresses (must be 3)"
  type        = list(string)
  default     = ["10.0.0.211", "10.0.0.212", "10.0.0.213"]
}

variable "master_cpu" {
  type    = number
  default = 4
}

variable "master_memory" {
  description = "RAM in MB"
  type        = number
  default     = 4096
}

variable "master_disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 50
}

# ----------------------------------------------------------
# Worker nodes configuration
# ----------------------------------------------------------

variable "worker_ips" {
  description = "Worker node IP addresses"
  type        = list(string)
  default     = ["10.0.0.214", "10.0.0.215"]
}

variable "worker_cpu" {
  type    = number
  default = 4
}

variable "worker_memory" {
  description = "RAM in MB"
  type        = number
  default     = 8192
}

variable "worker_disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 100
}

# ----------------------------------------------------------
# VM ID range
# ----------------------------------------------------------

variable "vm_id_offset" {
  description = "Starting VM ID (admin = offset, masters = offset+1..3, workers = offset+4..)"
  type        = number
  default     = 200
}
