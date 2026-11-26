# Terraform and provider requirements.
terraform {
  required_version = ">= 1.3"

  required_providers {
    # Installs Helm charts. Pinned to the 2.x line: 3.x changed the
    # provider's configuration syntax (blocks became attributes).
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    # Creates namespaces and secrets.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    # Generates the cookie encryption secret.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}
