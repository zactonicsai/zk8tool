output "cluster_id" {
  description = "ID of the cluster."
  value       = digitalocean_kubernetes_cluster.this.id
}

output "endpoint" {
  description = "Kubernetes API server URL."
  value       = digitalocean_kubernetes_cluster.this.endpoint
}

output "kubernetes_version" {
  description = "Version slug the cluster was created with."
  value       = local.version
}

output "kubeconfig" {
  description = "Kubeconfig (terraform output -raw kubeconfig)."
  value       = digitalocean_kubernetes_cluster.this.kube_config[0].raw_config
  sensitive   = true
}
