variable "compartment_id" {
  description = "OCI compartment OCID for all resources"
  type        = string
}

variable "admin_cidr" {
  description = "Administrator public IP in CIDR notation"
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && !strcontains(var.admin_cidr, "/0")
    error_message = "admin_cidr must be a restricted CIDR, not /0."
  }
}

variable "ssh_public_key_path" {
  description = "SSH public key for OKE workers and the bastion"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "oci_profile" {
  description = "OCI CLI profile used by the provider"
  type        = string
  default     = "k8s-tf"
}

