# Azure Kubernetes Service (AKS) cluster.
#
# Authentication: run `az login` first (or set the ARM_* environment
# variables for a service principal).
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# Override settings in terraform.tfvars (see terraform.tfvars.example).

provider "azurerm" {
  features {}

  # azurerm 4.x needs a subscription. null = use ARM_SUBSCRIPTION_ID.
  subscription_id = var.subscription_id
}

# ---------------------------------------------------------------------------
# Resource group: created here, or looked up when it already exists.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1

  name = var.resource_group_name
}

locals {
  resource_group_name = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
}

# ---------------------------------------------------------------------------
# Cluster and system node pool
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = local.resource_group_name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version # null = AKS default version
  sku_tier            = var.sku_tier
  tags                = var.tags

  # true = the API server is only reachable from inside the virtual network.
  private_cluster_enabled = var.private_cluster_enabled

  # Workload identity needs the OIDC issuer, so it switches it on as well.
  oidc_issuer_enabled       = var.oidc_issuer_enabled || var.workload_identity_enabled
  workload_identity_enabled = var.workload_identity_enabled

  # The system pool runs the cluster's own components (CoreDNS, metrics
  # server, ...). Changing vm_size or zones recreates it.
  default_node_pool {
    name            = var.system_node_pool.name
    vm_size         = var.system_node_pool.vm_size
    os_disk_size_gb = var.system_node_pool.os_disk_size_gb
    zones           = var.system_node_pool.zones
    node_labels     = var.system_node_pool.labels
    vnet_subnet_id  = var.vnet_subnet_id

    # Fixed size, or autoscaled between min and max. With autoscaling the
    # pool starts at min and node_count is left to the autoscaler.
    auto_scaling_enabled = var.system_node_pool.autoscaling != null
    node_count           = var.system_node_pool.autoscaling == null ? var.system_node_pool.node_count : null
    min_count            = try(var.system_node_pool.autoscaling.min, null)
    max_count            = try(var.system_node_pool.autoscaling.max, null)
  }

  # Managed identity for the control plane; no service principal secret to rotate.
  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = var.network_plugin
    network_plugin_mode = var.network_plugin_mode
    network_policy      = var.network_policy
    # The Cilium network policy engine requires the Cilium data plane.
    network_data_plane = var.network_policy == "cilium" ? "cilium" : null
    pod_cidr           = var.pod_cidr
    service_cidr       = var.service_cidr
    dns_service_ip     = var.dns_service_ip
  }

  # SSH access to the nodes; only configured when a public key is given.
  dynamic "linux_profile" {
    for_each = var.ssh_public_key_path == null ? [] : [1]
    content {
      admin_username = var.admin_username
      ssh_key {
        key_data = trimspace(file(pathexpand(var.ssh_public_key_path)))
      }
    }
  }
}

# ---------------------------------------------------------------------------
# User node pools: one per entry in var.user_node_pools.
# Add, remove or resize pools by editing that map in terraform.tfvars.
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = var.user_node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = each.value.vm_size
  os_disk_size_gb       = each.value.os_disk_size_gb
  zones                 = each.value.zones
  node_labels           = each.value.labels
  node_taints           = each.value.taints # "key=value:Effect"
  vnet_subnet_id        = var.vnet_subnet_id

  auto_scaling_enabled = each.value.autoscaling != null
  node_count           = each.value.autoscaling == null ? each.value.node_count : null
  min_count            = try(each.value.autoscaling.min, null)
  max_count            = try(each.value.autoscaling.max, null)

  # Spot nodes are cheaper but can be evicted at any time.
  # spot_max_price -1 = pay up to the on-demand price.
  priority        = each.value.spot ? "Spot" : "Regular"
  eviction_policy = each.value.spot ? "Delete" : null
  spot_max_price  = each.value.spot ? -1 : null
}

# ---------------------------------------------------------------------------
# Optional extras
# ---------------------------------------------------------------------------

# Let the nodes pull images from a container registry.
resource "azurerm_role_assignment" "acr_pull" {
  count = var.acr_id == null ? 0 : 1

  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# Write the admin kubeconfig to a file. The credentials are also stored in
# the Terraform state either way, so protect the state.
resource "local_sensitive_file" "kubeconfig" {
  count = var.kubeconfig_path == null ? 0 : 1

  content         = azurerm_kubernetes_cluster.this.kube_config_raw
  filename        = pathexpand(var.kubeconfig_path)
  file_permission = "0600"
}
