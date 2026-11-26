# Input variables. Set them in terraform.tfvars (see terraform.tfvars.example
# and the provider-specific files in examples/).

# --- Cluster access -----------------------------------------------------------

variable "kubeconfig_path" {
  description = "Kubeconfig file for the cluster to install into."
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "Context in that kubeconfig. null = the current context."
  type        = string
  default     = null
}

# --- Your site ----------------------------------------------------------------

variable "hosts" {
  description = "Host names that require sign-in. The first one is used for the sign-in redirect URL."
  type        = list(string)

  validation {
    condition     = length(var.hosts) > 0
    error_message = "Give at least one host name, e.g. [\"app.example.com\"]."
  }
}

variable "tls_enabled" {
  description = "Serve HTTPS (true, recommended) or plain HTTP (false, local testing only)."
  type        = bool
  default     = true
}

variable "tls_secret_name" {
  description = "Name of the kubernetes.io/tls secret in istio-ingress that holds the certificate for the hosts."
  type        = string
  default     = "sso-gateway-tls"
}

variable "tls_cert_file" {
  description = "Certificate file (PEM). Set together with tls_key_file to have Terraform create the TLS secret. null = the secret already exists."
  type        = string
  default     = null
}

variable "tls_key_file" {
  description = "Private key file (PEM) for tls_cert_file."
  type        = string
  default     = null
}

variable "external_port" {
  description = "Port people type in the browser when it is not 80/443 (local clusters), e.g. 8443. null = standard port."
  type        = number
  default     = null
}

variable "public_paths" {
  description = "Paths that do not require sign-in, e.g. [\"/healthz\", \"/public/*\"]."
  type        = list(string)
  default     = []
}

# --- Identity provider (OpenID Connect) --------------------------------------

variable "oidc_issuer_url" {
  description = "Issuer URL of your identity provider, e.g. https://login.microsoftonline.com/<tenant-id>/v2.0"
  type        = string
}

variable "oidc_client_id" {
  description = "Client (application) ID registered with the identity provider."
  type        = string
}

variable "oidc_client_secret" {
  description = "Client secret. Prefer the environment variable TF_VAR_oidc_client_secret over writing it in a file."
  type        = string
  sensitive   = true
}

variable "oidc_scopes" {
  description = "Scopes requested at sign-in."
  type        = string
  default     = "openid email profile"
}

variable "allowed_email_domains" {
  description = "E-mail domains allowed to sign in. [\"*\"] = everyone your identity provider lets in."
  type        = list(string)
  default     = ["*"]
}

variable "cookie_domain" {
  description = "Share one sign-in across sub-domains, e.g. \".example.com\". null = each host has its own session."
  type        = string
  default     = null
}

variable "oidc_extra_args" {
  description = "Extra oauth2-proxy flags (without the leading --), for provider-specific settings."
  type        = map(string)
  default     = {}
}

# --- Ingress gateway ----------------------------------------------------------

variable "gateway_service_type" {
  description = "LoadBalancer (cloud clusters) or NodePort (local clusters such as kind)."
  type        = string
  default     = "LoadBalancer"

  validation {
    condition     = contains(["LoadBalancer", "NodePort", "ClusterIP"], var.gateway_service_type)
    error_message = "Must be LoadBalancer, NodePort or ClusterIP."
  }
}

variable "gateway_service_annotations" {
  description = "Annotations for the gateway's Service, e.g. to request an internal load balancer."
  type        = map(string)
  default     = {}
}

variable "gateway_node_ports" {
  description = "Fixed node ports for HTTP and HTTPS when gateway_service_type is NodePort. null = assigned by Kubernetes."
  type        = object({ http = number, https = number })
  default     = null
}

# --- Versions and extras ------------------------------------------------------

variable "istio_version" {
  description = "Istio chart version for base, istiod and gateway, e.g. \"1.31.0\". null = latest. Pin it once things work."
  type        = string
  default     = null
}

variable "oauth2_proxy_chart_version" {
  description = "oauth2-proxy chart version. null = latest. Pin it once things work."
  type        = string
  default     = null
}

variable "deploy_demo_app" {
  description = "Install the httpbin test app behind sign-in."
  type        = bool
  default     = true
}
