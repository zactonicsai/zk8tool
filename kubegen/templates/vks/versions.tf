# Terraform and provider requirements.
terraform {
  # terraform_data (used for the wait and kubeconfig steps) needs 1.4.
  required_version = ">= 1.4"

  required_providers {
    # Applies the Cluster manifest to the Supervisor, like `kubectl apply`.
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0"
    }
  }
}
