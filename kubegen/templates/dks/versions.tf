# Terraform and provider requirements.
terraform {
  required_version = ">= 1.3"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    # Only used to write the kubeconfig file when kubeconfig_path is set.
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }
}
