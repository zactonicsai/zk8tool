output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.this.name
}

output "endpoint" {
  description = "IP address of the Kubernetes API server."
  value       = google_container_cluster.this.endpoint
}

output "kubernetes_version" {
  description = "Version the control plane is running."
  value       = google_container_cluster.this.master_version
}

output "get_credentials_command" {
  description = "Command that adds the cluster to your kubeconfig (needs gke-gcloud-auth-plugin)."
  value = join(" ", compact([
    var.kubeconfig_path == null ? "" : "KUBECONFIG=${var.kubeconfig_path}",
    "gcloud container clusters get-credentials ${google_container_cluster.this.name}",
    "--project ${var.project} --location ${var.location}",
  ]))
}
