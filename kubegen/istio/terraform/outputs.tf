output "redirect_uri" {
  description = "Register this exact URL as a redirect URI in your identity provider."
  value       = local.redirect_url
}

output "site_url" {
  description = "Open this after DNS points at the gateway; you should be asked to sign in."
  value       = local.external_url
}

output "test_url" {
  description = "Shows the headers your apps receive after sign-in (demo app only)."
  value       = var.deploy_demo_app ? "${local.external_url}/headers" : null
}

output "sign_out_url" {
  description = "Ends the session at the gateway."
  value       = "${local.external_url}/oauth2/sign_out"
}

output "gateway_address_command" {
  description = "Shows the gateway's external address, to point DNS at."
  value       = "kubectl get service istio-ingress -n istio-ingress"
}

output "gateway_for_virtualservices" {
  description = "Value for spec.gateways in your own VirtualServices."
  value       = "istio-ingress/sso-gateway"
}

output "keycloak_admin_url" {
  description = "Keycloak admin console (only with var.keycloak)."
  value       = local.use_keycloak ? "${local.scheme}://${var.keycloak.host}${local.port_suffix}/admin" : null
}
