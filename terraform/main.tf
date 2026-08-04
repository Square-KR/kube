locals {
  region             = "ap-seoul-1"
  vcn_cidr           = "10.20.0.0/16"
  public_subnet_cidr = "10.20.0.0/24"
  worker_subnet_cidr = "10.20.1.0/24"
  pod_cidr           = "10.244.0.0/16"
  service_cidr       = "10.96.0.0/16"
  kubernetes_version = "v1.33.10"
  oke_image_name     = "Oracle-Linux-9.8-aarch64-2026.07.20-0-OKE-1.33.10-1578"
  shape              = "VM.Standard.A1.Flex"

  availability_domain = data.oci_identity_availability_domains.available.availability_domains[0].name
  oke_image_id = one([
    for source in data.oci_containerengine_node_pool_option.available.sources : source.image_id
    if source.source_name == local.oke_image_name
  ])
  tags = {
    "managed-by" = "terraform"
    project      = "squarek8s"
  }
}

data "oci_identity_availability_domains" "available" {
  compartment_id = var.compartment_id
}

data "oci_identity_fault_domains" "available" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_id
}

data "oci_core_services" "available" {}

data "oci_core_images" "bastion" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = local.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_containerengine_node_pool_option" "available" {
  compartment_id      = var.compartment_id
  node_pool_option_id = "all"
}

resource "oci_core_vcn" "main" {
  cidr_blocks    = [local.vcn_cidr]
  compartment_id = var.compartment_id
  display_name   = "squarek8s-vcn"
  dns_label      = "squarek8s"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_id
  display_name   = "squarek8s-internet-gateway"
  enabled        = true
  freeform_tags  = local.tags
  vcn_id         = oci_core_vcn.main.id
}

resource "oci_core_nat_gateway" "main" {
  compartment_id = var.compartment_id
  display_name   = "squarek8s-nat-gateway"
  freeform_tags  = local.tags
  vcn_id         = oci_core_vcn.main.id
}

resource "oci_core_service_gateway" "main" {
  compartment_id = var.compartment_id
  display_name   = "squarek8s-service-gateway"
  freeform_tags  = local.tags
  vcn_id         = oci_core_vcn.main.id

  services {
    service_id = data.oci_core_services.available.services[0].id
  }
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  display_name   = "squarek8s-public-routes"
  freeform_tags  = local.tags
  vcn_id         = oci_core_vcn.main.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  display_name   = "squarek8s-private-routes"
  freeform_tags  = local.tags
  vcn_id         = oci_core_vcn.main.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.main.id
  }

  route_rules {
    destination       = data.oci_core_services.available.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.main.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  display_name   = "squarek8s-public-security-list"
  freeform_tags  = local.tags
  vcn_id         = oci_core_vcn.main.id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "all"
    source   = local.vcn_cidr
  }

  dynamic "ingress_security_rules" {
    for_each = toset([80, 443])
    content {
      protocol = "6"
      source   = "0.0.0.0/0"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset([22, 6443])
    content {
      protocol = "6"
      source   = var.admin_cidr
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = local.worker_subnet_cidr
    tcp_options {
      min = 5432
      max = 5432
    }
  }

  lifecycle {
    ignore_changes = [egress_security_rules]
  }
}

resource "oci_core_security_list" "workers" {
  compartment_id = var.compartment_id
  display_name   = "squarek8s-worker-security-list"
  freeform_tags  = local.tags
  vcn_id         = oci_core_vcn.main.id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "all"
    source   = local.vcn_cidr
  }

  lifecycle {
    ignore_changes = [ingress_security_rules]
  }
}

resource "oci_core_subnet" "public" {
  cidr_block                 = local.public_subnet_cidr
  compartment_id             = var.compartment_id
  display_name               = "squarek8s-public-subnet"
  dns_label                  = "public"
  freeform_tags              = local.tags
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  vcn_id                     = oci_core_vcn.main.id
}

resource "oci_core_subnet" "workers" {
  cidr_block                 = local.worker_subnet_cidr
  compartment_id             = var.compartment_id
  display_name               = "squarek8s-worker-subnet"
  dns_label                  = "workers"
  freeform_tags              = local.tags
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.workers.id]
  vcn_id                     = oci_core_vcn.main.id
}

resource "oci_containerengine_cluster" "main" {
  compartment_id     = var.compartment_id
  kubernetes_version = local.kubernetes_version
  name               = "squarek8s"
  type               = "BASIC_CLUSTER"
  vcn_id             = oci_core_vcn.main.id
  freeform_tags      = local.tags

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = oci_core_subnet.public.id
  }

  options {
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = local.pod_cidr
      services_cidr = local.service_cidr
    }

    service_lb_subnet_ids = [oci_core_subnet.public.id]
  }
}

resource "oci_containerengine_node_pool" "workers" {
  cluster_id         = oci_containerengine_cluster.main.id
  compartment_id     = var.compartment_id
  kubernetes_version = local.kubernetes_version
  name               = "squarek8s-workers"
  node_shape         = local.shape
  freeform_tags      = local.tags
  ssh_public_key     = file(pathexpand(var.ssh_public_key_path))

  initial_node_labels {
    key   = "node-role"
    value = "worker"
  }

  node_config_details {
    size = 2

    placement_configs {
      availability_domain = local.availability_domain
      fault_domains       = data.oci_identity_fault_domains.available.fault_domains[*].name
      subnet_id           = oci_core_subnet.workers.id
    }
  }

  node_shape_config {
    memory_in_gbs = 8
    ocpus         = 1
  }

  node_source_details {
    boot_volume_size_in_gbs = 50
    image_id                = local.oke_image_id
    source_type             = "IMAGE"
  }
}

resource "oci_core_instance" "bastion" {
  availability_domain  = local.availability_domain
  compartment_id       = var.compartment_id
  display_name         = "squarek8s-bastion-db"
  fault_domain         = data.oci_identity_fault_domains.available.fault_domains[0].name
  freeform_tags        = local.tags
  preserve_boot_volume = false
  shape                = local.shape

  shape_config {
    memory_in_gbs = 8
    ocpus         = 2
  }

  create_vnic_details {
    assign_public_ip = true
    display_name     = "squarek8s-bastion-db"
    hostname_label   = "bastion-db"
    private_ip       = "10.20.0.45"
    subnet_id        = oci_core_subnet.public.id
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
  }

  source_details {
    boot_volume_size_in_gbs = 50
    source_id               = data.oci_core_images.bastion.images[0].id
    source_type             = "image"
  }
}

resource "oci_core_volume" "postgres" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_id
  display_name        = "squarek8s-postgres-data"
  freeform_tags       = local.tags
  size_in_gbs         = 50
  vpus_per_gb         = 10
}

resource "oci_core_volume_attachment" "postgres" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.bastion.id
  is_read_only    = false
  is_shareable    = false
  volume_id       = oci_core_volume.postgres.id
}
