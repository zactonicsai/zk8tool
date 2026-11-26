# Istio with SSO sign-in at the ingress gateway.
#
# What gets installed, in order:
#   1. istio-base     Istio's custom resource definitions
#   2. istiod         the Istio control plane, with oauth2-proxy registered
#                     as an external authorizer
#   3. istio-ingress  the ingress gateway (Envoy) that receives outside traffic
#   4. oauth2-proxy   runs the sign-in against your identity provider
#   5. sso-config     the Gateway and the policy that requires sign-in
#
# How sign-in works once it is running:
#   browser -> ingress gateway -> "is this request signed in?" -> oauth2-proxy
#     yes: the request goes on to your app with X-Auth-Request-* headers
#     no:  the browser is redirected to your identity provider, signs in,
#          comes back to /oauth2/callback, gets a session cookie, and is
#          sent on to the page it asked for
#
# The cluster must already exist and your kubeconfig must point at it.
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars    # then fill it in
#   terraform init
#   terraform plan
#   terraform apply
#
# The Helm values come from ../helm/values, so Terraform and the helm CLI
# (../helm/install.sh) install the same thing. Use one or the other.

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kubeconfig_context # null = current context
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kubeconfig_context
  }
}

locals {
  istio_repo = "https://istio-release.storage.googleapis.com/charts"
  values_dir = "${path.module}/../helm/values"

  # The address people type in the browser, e.g. https://app.example.com
  scheme       = var.tls_enabled ? "https" : "http"
  port_suffix  = var.external_port == null ? "" : ":${var.external_port}"
  external_url = "${local.scheme}://${var.hosts[0]}${local.port_suffix}"

  # The identity provider sends people back here after sign-in.
  redirect_url = "${local.external_url}/oauth2/callback"

  # Create the TLS secret here only when certificate files are given.
  create_tls_secret = var.tls_enabled && var.tls_cert_file != null && var.tls_key_file != null
}

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
  }
}

resource "kubernetes_namespace" "istio_ingress" {
  metadata {
    name = "istio-ingress"
  }
}

resource "kubernetes_namespace" "oauth2_proxy" {
  metadata {
    name = "oauth2-proxy"
  }
}

# ---------------------------------------------------------------------------
# 1-3. Istio
# ---------------------------------------------------------------------------

resource "helm_release" "istio_base" {
  name       = "istio-base"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = local.istio_repo
  chart      = "base"
  version    = var.istio_version # null = latest

  values = [file("${local.values_dir}/istio-base.yaml")]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = local.istio_repo
  chart      = "istiod"
  version    = var.istio_version

  # istiod.yaml registers oauth2-proxy as the "oauth2-proxy" extension
  # provider; the sign-in policy below refers to it by that name.
  values = [file("${local.values_dir}/istiod.yaml")]

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "ingress_gateway" {
  # The release name decides the pod label: istio-ingress -> istio=ingress,
  # which the Gateway and the sign-in policy select on. Do not rename it
  # without changing gateway.selector in the sso-config chart.
  name       = "istio-ingress"
  namespace  = kubernetes_namespace.istio_ingress.metadata[0].name
  repository = local.istio_repo
  chart      = "gateway"
  version    = var.istio_version

  values = [
    file("${local.values_dir}/gateway.yaml"),
    yamlencode({
      service = {
        # Entries that are null are left out, so the chart default applies.
        for k, v in {
          type        = var.gateway_service_type
          annotations = var.gateway_service_annotations
          # Fixed node ports, for local clusters that map host ports to them.
          ports = var.gateway_node_ports == null ? null : [
            { name = "status-port", port = 15021, targetPort = 15021, protocol = "TCP" },
            { name = "http2", port = 80, targetPort = 80, protocol = "TCP", nodePort = var.gateway_node_ports.http },
            { name = "https", port = 443, targetPort = 443, protocol = "TCP", nodePort = var.gateway_node_ports.https },
          ]
        } : k => v if v != null
      }
    }),
  ]

  # A LoadBalancer service never becomes "ready" on a cluster without a load
  # balancer (such as kind), which would make Terraform wait until it times
  # out. Only wait where an address is not expected.
  wait = var.gateway_service_type != "LoadBalancer"

  depends_on = [helm_release.istiod]
}

# ---------------------------------------------------------------------------
# 4. oauth2-proxy (the sign-in service)
# ---------------------------------------------------------------------------

# Encrypts the session cookie. Changing it signs everyone out.
resource "random_password" "cookie_secret" {
  length  = 32 # oauth2-proxy needs exactly 16, 24 or 32 bytes
  special = false
}

# Credentials live in a Kubernetes secret, not in Helm values. They are also
# stored in the Terraform state, so keep the state private.
resource "kubernetes_secret" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy-credentials"
    namespace = kubernetes_namespace.oauth2_proxy.metadata[0].name
  }

  data = {
    "client-id"     = var.oidc_client_id
    "client-secret" = var.oidc_client_secret
    "cookie-secret" = random_password.cookie_secret.result
  }
}

resource "helm_release" "oauth2_proxy" {
  name       = "oauth2-proxy"
  namespace  = kubernetes_namespace.oauth2_proxy.metadata[0].name
  repository = "https://oauth2-proxy.github.io/manifests"
  chart      = "oauth2-proxy"
  version    = var.oauth2_proxy_chart_version # null = latest

  values = [
    file("${local.values_dir}/oauth2-proxy.yaml"),
    yamlencode({
      config = {
        existingSecret = kubernetes_secret.oauth2_proxy.metadata[0].name
        configFile     = <<-EOT
          email_domains = [ ${join(", ", [for d in var.allowed_email_domains : "\"${d}\""])} ]
          upstreams = [ "static://200" ]
        EOT
      }
      extraArgs = merge(
        {
          "oidc-issuer-url" = var.oidc_issuer_url
          "redirect-url"    = local.redirect_url
          "scope"           = var.oidc_scopes
          # Secure cookies need HTTPS; relaxed only for local HTTP testing.
          "cookie-secure" = tostring(var.tls_enabled)
        },
        # Share the session across sub-domains, e.g. ".example.com".
        {
          for k in ["cookie-domain", "whitelist-domain"] : k => var.cookie_domain
          if var.cookie_domain != null
        },
        # Provider-specific flags; see the files in examples/.
        var.oidc_extra_args,
      )
    }),
  ]

  # No depends_on for Istio: oauth2-proxy runs without a sidecar and only
  # needs its namespace and secret.
}

# ---------------------------------------------------------------------------
# 5. Gateway and sign-in policy
# ---------------------------------------------------------------------------

# Certificate for HTTPS, when certificate files are given. Otherwise the
# secret named by tls_secret_name must already exist in istio-ingress
# (created by hand or by cert-manager).
resource "kubernetes_secret" "gateway_tls" {
  count = local.create_tls_secret ? 1 : 0

  metadata {
    name      = var.tls_secret_name
    namespace = kubernetes_namespace.istio_ingress.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = file(pathexpand(var.tls_cert_file))
    "tls.key" = file(pathexpand(var.tls_key_file))
  }
}

resource "helm_release" "sso_config" {
  name      = "sso-config"
  namespace = kubernetes_namespace.istio_ingress.metadata[0].name
  chart     = "${path.module}/../helm/sso-config" # local chart in this repo

  values = [
    yamlencode({
      hosts = var.hosts
      gateway = {
        tls = {
          enabled        = var.tls_enabled
          credentialName = var.tls_secret_name
        }
      }
      signIn = {
        publicPaths = var.public_paths
      }
      demoApp = {
        enabled = var.deploy_demo_app
      }
    }),
  ]

  # Needs Istio's resource types, the gateway it attaches to, and
  # oauth2-proxy to be answering before sign-in is enforced.
  depends_on = [
    helm_release.istiod,
    helm_release.ingress_gateway,
    helm_release.oauth2_proxy,
    kubernetes_secret.gateway_tls,
  ]
}
