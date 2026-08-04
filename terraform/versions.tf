terraform {
  required_version = ">= 1.12.2"

  backend "oci" {}

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.32.0"
    }
  }
}

provider "oci" {
  config_file_profile = var.oci_profile
  region              = local.region
}

