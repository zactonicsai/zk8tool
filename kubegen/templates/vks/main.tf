# VMware vSphere Kubernetes Service (VKS) workload cluster.
#
# A VKS cluster is created by applying a Cluster API "Cluster" object to a
# vSphere Namespace on the Supervisor. This configuration builds that object
# from the variables, applies it, waits for the cluster and fetches its
# kubeconfig.
#
# Authentication: Terraform cannot log in to the Supervisor for you. Log in
# first so the kubeconfig below holds a valid session, e.g.
#   kubectl vsphere login --server <supervisor> --vsphere-username <user>
# and repeat when the session token expires.
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# Override settings in terraform.tfvars (see terraform.tfvars.example).
# The wait and kubeconfig steps run kubectl and a POSIX shell locally.

provider "kubectl" {
  config_path      = pathexpand(var.supervisor_kubeconfig_path)
  config_context   = var.supervisor_context # null = the kubeconfig's current context
  load_config_file = true
}

locals {
  # Optional pod / service network settings; unset values are left out so
  # the ClusterClass defaults apply.
  cluster_network = {
    for k, v in {
      pods          = var.pod_cidr == null ? null : { cidrBlocks = [var.pod_cidr] }
      services      = var.service_cidr == null ? null : { cidrBlocks = [var.service_cidr] }
      serviceDomain = var.service_domain
    } : k => v if v != null
  }

  # One machineDeployment per entry in var.node_pools.
  machine_deployments = [
    for name, pool in var.node_pools : {
      for k, v in {
        class = "node-pool"
        name  = name

        # Fixed size: set replicas. Autoscaled: replicas must stay unset and
        # the Cluster Autoscaler reads its bounds from these annotations
        # (the autoscaler package has to be installed on the cluster).
        replicas = pool.autoscaling == null ? pool.node_count : null
        metadata = pool.autoscaling == null ? null : {
          annotations = {
            "cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size" = tostring(pool.autoscaling.min)
            "cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size" = tostring(pool.autoscaling.max)
          }
        }

        # Per-pool VM class; pools without one use var.vm_class.
        variables = pool.vm_class == null ? null : {
          overrides = [{ name = "vmClass", value = pool.vm_class }]
        }
      } : k => v if v != null
    }
  ]

  cluster = {
    apiVersion = var.cluster_api_version
    kind       = "Cluster"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      for k, v in {
        clusterNetwork = length(local.cluster_network) > 0 ? local.cluster_network : null
        topology = {
          for k, v in {
            class          = var.cluster_class
            classNamespace = var.cluster_class_namespace
            version        = var.kubernetes_version
            controlPlane   = { replicas = var.control_plane_replicas }
            variables = [
              { name = "vmClass", value = var.vm_class },
              { name = "storageClass", value = var.storage_class },
            ]
            workers = { machineDeployments = local.machine_deployments }
          } : k => v if v != null
        }
      } : k => v if v != null
    }
  }

  # kubectl invocation against the Supervisor, used by the local steps below.
  kubectl = join(" ", compact([
    "kubectl",
    "--kubeconfig=${pathexpand(var.supervisor_kubeconfig_path)}",
    var.supervisor_context == null ? "" : "--context=${var.supervisor_context}",
  ]))
}

# The cluster itself. Destroying this resource deletes the cluster.
resource "kubectl_manifest" "cluster" {
  yaml_body = yamlencode(local.cluster)
}

# Wait until the Supervisor reports the cluster ready (provisioning the
# control plane and nodes usually takes 10-30 minutes).
resource "terraform_data" "wait_ready" {
  depends_on = [kubectl_manifest.cluster]

  provisioner "local-exec" {
    command = "${local.kubectl} wait --for=condition=${var.ready_condition} cluster/${var.name} -n ${var.namespace} --timeout=${var.wait_timeout}"
  }
}

# Save the workload cluster's kubeconfig. Cluster API keeps it in the secret
# <name>-kubeconfig in the vSphere Namespace.
resource "terraform_data" "kubeconfig" {
  depends_on = [terraform_data.wait_ready]

  # Fetch again when the target path changes.
  triggers_replace = [var.kubeconfig_path]

  provisioner "local-exec" {
    command = "umask 077 && ${local.kubectl} get secret ${var.name}-kubeconfig -n ${var.namespace} -o jsonpath='{.data.value}' | base64 -d > '${pathexpand(var.kubeconfig_path)}'"
  }
}
