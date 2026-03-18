############################################################
#  PROMĚNNÉ - edituj terraform.tfvars                     #
############################################################

variable "proxmox_endpoint" {
  description = "URL Proxmox API, např. https://10.0.0.1:8006"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox uživatel ve formátu user@realm, např. terraform@pve"
  type        = string
  default     = "terraform@pve"
}

variable "proxmox_api_token" {
  description = "API token ve formátu terraform@pve!mytoken=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Název Proxmox nodu, na kterém se budou vytvářet VM"
  type        = string
  default     = "pve"
}

variable "proxmox_insecure" {
  description = "Přeskočit ověření TLS certifikátu (self-signed cert)"
  type        = bool
  default     = true
}

# ----------------------------------------------------------
# Template / Cloud-Init
# ----------------------------------------------------------

variable "template_id" {
  description = "VM ID šablony (Ubuntu cloud-init template)"
  type        = number
  default     = 9000
}

variable "datastore_id" {
  description = "Proxmox datastore pro disky VM (local-lvm, ceph, atd.)"
  type        = string
  default     = "local-lvm"
}

variable "iso_datastore_id" {
  description = "Proxmox datastore pro cloud-init ISO"
  type        = string
  default     = "local"
}

# ----------------------------------------------------------
# Síťová konfigurace
# ----------------------------------------------------------

variable "network_gateway" {
  description = "Výchozí brána sítě"
  type        = string
  default     = "10.0.0.1"
}

variable "network_bridge" {
  description = "Proxmox síťový bridge"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag (0 = bez VLANu)"
  type        = number
  default     = 0
}

variable "dns_server" {
  description = "DNS server pro VM"
  type        = string
  default     = "8.8.8.8"
}

variable "dns_domain" {
  description = "DNS doménový suffix"
  type        = string
  default     = "local"
}

# ----------------------------------------------------------
# SSH klíč pro cloud-init
# ----------------------------------------------------------

variable "ssh_public_key" {
  description = "Obsah SSH veřejného klíče pro uživatele ubuntu"
  type        = string
}

variable "vm_user" {
  description = "Uživatel na VM (musí odpovídat skriptu)"
  type        = string
  default     = "ubuntu"
}

# ----------------------------------------------------------
# Konfigurace admin nodu
# ----------------------------------------------------------

variable "admin_ip" {
  description = "IP adresa admin nodu"
  type        = string
  default     = "10.0.0.210"
}

variable "admin_cpu" {
  type    = number
  default = 2
}

variable "admin_memory" {
  description = "RAM v MB"
  type        = number
  default     = 2048
}

variable "admin_disk_size" {
  description = "Velikost disku v GB"
  type        = number
  default     = 20
}

# ----------------------------------------------------------
# Konfigurace master nodů
# ----------------------------------------------------------

variable "master_ips" {
  description = "IP adresy master nodů (musí být 3)"
  type        = list(string)
  default     = ["10.0.0.211", "10.0.0.212", "10.0.0.213"]
}

variable "master_cpu" {
  type    = number
  default = 4
}

variable "master_memory" {
  description = "RAM v MB"
  type        = number
  default     = 4096
}

variable "master_disk_size" {
  description = "Velikost disku v GB"
  type        = number
  default     = 50
}

# ----------------------------------------------------------
# Konfigurace worker nodů
# ----------------------------------------------------------

variable "worker_ips" {
  description = "IP adresy worker nodů"
  type        = list(string)
  default     = ["10.0.0.214", "10.0.0.215"]
}

variable "worker_cpu" {
  type    = number
  default = 4
}

variable "worker_memory" {
  description = "RAM v MB"
  type        = number
  default     = 8192
}

variable "worker_disk_size" {
  description = "Velikost disku v GB"
  type        = number
  default     = 100
}

# ----------------------------------------------------------
# VM ID rozsah
# ----------------------------------------------------------

variable "vm_id_offset" {
  description = "Počáteční VM ID (admin = offset, masters = offset+1..3, workers = offset+4..)"
  type        = number
  default     = 200
}
