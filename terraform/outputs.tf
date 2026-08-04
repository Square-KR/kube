output "cluster_id" {
  description = "OKE cluster OCID"
  value       = oci_containerengine_cluster.main.id
}

output "kubeconfig_command" {
  description = "Command to create the kubeconfig for the public OKE endpoint"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.main.id} --file ~/.kube/oke-squarek8s --region ${local.region} --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT --profile ${var.oci_profile}"
}

output "bastion_public_ip" {
  value = oci_core_instance.bastion.public_ip
}

output "bastion_private_ip" {
  value = oci_core_instance.bastion.private_ip
}

output "postgres_volume_id" {
  value = oci_core_volume.postgres.id
}

output "load_balancer_subnet_id" {
  value = oci_core_subnet.public.id
}

