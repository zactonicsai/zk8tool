output "cluster_name" {
  description = "Name of the kind cluster."
  value       = terraform_data.cluster.output.name
}

output "kubectl_context" {
  description = "kubectl context kind created for the cluster."
  value       = "kind-${terraform_data.cluster.output.name}"
}

output "kind_config" {
  description = "The kind configuration the cluster was created with."
  value       = local.kind_config_yaml
}

output "get_kubeconfig_command" {
  description = "Command that prints the cluster's kubeconfig."
  value       = "KIND_EXPERIMENTAL_PROVIDER=podman kind get kubeconfig --name ${terraform_data.cluster.output.name}"
}
