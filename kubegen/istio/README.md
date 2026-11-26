# Istio with SSO sign-in

Installs Istio on a cluster you already have and makes everything behind its
ingress gateway require sign-in through your identity provider (Microsoft
Entra ID, Okta, Google, Keycloak, or any other OpenID Connect provider).
Your apps need no login code of their own.

    browser --> Istio ingress gateway --"signed in?"--> oauth2-proxy <--> identity provider
                        |
                        +--> your app (receives X-Auth-Request-Email and friends)

## What is in this directory

| Path                                 | Purpose                                                        |
|--------------------------------------|----------------------------------------------------------------|
| `helm/values/istio-base.yaml`        | Values for Istio's base chart (resource definitions)           |
| `helm/values/istiod.yaml`            | Values for the control plane; registers oauth2-proxy as the sign-in checker |
| `helm/values/gateway.yaml`           | Values for the ingress gateway                                 |
| `helm/values/oauth2-proxy.yaml`      | Values for oauth2-proxy, the service that runs the sign-in     |
| `helm/sso-config/`                   | Small Helm chart: the Istio Gateway, the sign-in policy, and a test app |
| `helm/install.sh`, `uninstall.sh`    | Install or remove everything with the `helm` command           |
| `terraform/`                         | Install everything with Terraform (uses the same values files) |
| `terraform/terraform.tfvars.example` | Every setting, with explanations                               |
| `terraform/examples/`                | Starting points for Entra ID, Okta, Google, Keycloak and a local kind cluster |

Terraform and `install.sh` install the same thing. **Pick one** and stay
with it.

## Before you start

| You need                          | Notes                                                              |
|-----------------------------------|--------------------------------------------------------------------|
| A running cluster                 | Any of the kubegen providers. `kubectl get nodes` must work.       |
| `kubectl`                         | <https://kubernetes.io/docs/tasks/tools/>                          |
| `terraform` **or** `helm`         | <https://developer.hashicorp.com/terraform/install> / <https://helm.sh/docs/intro/install/> |
| A host name                       | For example `app.example.com`, which you can point at the gateway  |
| A TLS certificate for that host   | From your certificate authority or cert-manager                    |
| Admin access to your identity provider | To register an application                                    |

## Step 1 - Register an application with your identity provider

Create a "web application" (OpenID Connect) registration and note three
values:

| Value         | Used as              |
|---------------|----------------------|
| Issuer URL    | `oidc_issuer_url`    |
| Client ID     | `oidc_client_id`     |
| Client secret | `oidc_client_secret` |

Register this redirect URI, replacing the host with yours:

    https://app.example.com/oauth2/callback

The files in `terraform/examples/` say where to click for each provider.

## Step 2 - Provide the TLS certificate

Sign-in cookies should only travel over HTTPS. Choose one:

- **Terraform creates the secret:** set `tls_cert_file` and `tls_key_file`.
- **You create it** (after Step 3 has made the namespace, or create the
  namespace first):

      kubectl create namespace istio-ingress
      kubectl create secret tls sso-gateway-tls -n istio-ingress --cert=cert.pem --key=key.pem

- **cert-manager** issues it into `istio-ingress` under the name
  `sso-gateway-tls`.

If you create the namespace by hand and then use Terraform, import it first:
`terraform import kubernetes_namespace.istio_ingress istio-ingress`.

## Step 3a - Install with Terraform

    cd istio/terraform
    cp terraform.tfvars.example terraform.tfvars      # or start from a file in examples/
    # edit terraform.tfvars: hosts, oidc_issuer_url, oidc_client_id

    export TF_VAR_oidc_client_secret='<client secret>'

    terraform init
    terraform plan
    terraform apply

At the end Terraform prints the redirect URI to register, the URL to test,
and the command that shows the gateway's address.

## Step 3b - Or install with Helm

    cd istio/helm
    export SSO_HOST=app.example.com
    export OIDC_ISSUER_URL=https://login.microsoftonline.com/<tenant-id>/v2.0
    export OIDC_CLIENT_ID='<client id>'
    export OIDC_CLIENT_SECRET='<client secret>'
    ./install.sh

The script checks for `helm`, `kubectl` and `openssl` and prints the
download link for any that are missing. Optional settings are listed at the
top of the script.

## Step 4 - Point DNS at the gateway

    kubectl get service istio-ingress -n istio-ingress

Create a DNS record for your host name pointing at the `EXTERNAL-IP` shown
(an address on Azure, Google and DigitalOcean; a host name on AWS, where
you use a CNAME).

## Step 5 - Test it

1. Open `https://app.example.com/headers` in a private browser window.
2. You should be sent to your identity provider's sign-in page.
3. After signing in you land back on the test app, which prints the request
   headers. Look for `X-Auth-Request-Email` with your address.
4. Open `https://app.example.com/oauth2/sign_out` to end the session.

## Step 6 - Put your own app behind sign-in

Give your app's namespace a sidecar and route the host to your Service:

    kubectl label namespace my-app istio-injection=enabled

    apiVersion: networking.istio.io/v1
    kind: VirtualService
    metadata:
      name: my-app
      namespace: my-app
    spec:
      hosts: ["app.example.com"]
      gateways: ["istio-ingress/sso-gateway"]
      http:
        - route:
            - destination:
                host: my-app.my-app.svc.cluster.local
                port:
                  number: 80

Then switch the test app off (`deploy_demo_app = false`, or `DEMO_APP=false`
for the script), because it routes the same host.

Your app reads who is signed in from these request headers:

| Header                               | Contains                          |
|--------------------------------------|-----------------------------------|
| `X-Auth-Request-Email`               | E-mail address                    |
| `X-Auth-Request-User`                | User ID at the identity provider  |
| `X-Auth-Request-Preferred-Username`  | Sign-in name                      |
| `X-Auth-Request-Groups`              | Groups, if the provider sends them|
| `Authorization: Bearer <ID token>`   | The signed token itself           |

## Common changes

| Goal                              | Terraform                                         | install.sh                    |
|-----------------------------------|---------------------------------------------------|-------------------------------|
| Only your company's accounts      | `allowed_email_domains = ["example.com"]`         | `EMAIL_DOMAINS=example.com`   |
| Keep some paths public            | `public_paths = ["/healthz", "/public/*"]`        | edit `sso-config/values.yaml` |
| One sign-in for several sub-domains | `hosts = [...]`, `cookie_domain = ".example.com"` | edit the values files         |
| Internal load balancer            | `gateway_service_annotations = {...}`             | edit `values/gateway.yaml`    |
| Pin versions                      | `istio_version`, `oauth2_proxy_chart_version`     | `ISTIO_VERSION=...`           |
| Try it on a local kind cluster    | `examples/local-kind.tfvars.example`              | `TLS_ENABLED=false EXTERNAL_PORT=8080 GATEWAY_SERVICE_TYPE=NodePort` |

## Gotchas

- **The redirect URI must match exactly.** Scheme, host, port and path. A
  trailing slash or `http` instead of `https` makes the provider refuse.
- **Google lets any Google account in** unless you set
  `allowed_email_domains`.
- **Entra ID may not send an `email` claim.** The Entra example uses
  `preferred_username` instead.
- **Sign-in protects the gateway, not the cluster network.** A pod inside
  the cluster can still call your app's Service directly. If that matters,
  add an Istio `AuthorizationPolicy` on the app that only allows traffic
  from the `istio-ingress` namespace.
- **Do not rename the gateway release.** The name `istio-ingress` produces
  the pod label `istio=ingress` that the Gateway and policy select on.
- **The client secret ends up in the Terraform state.** Keep the state
  private (remote backend with encryption, not a shared folder).
- **Changing the cookie secret signs everyone out.** Terraform generates it
  once and keeps it; `install.sh` reuses the existing one.
- **Unpinned versions.** By default the latest Istio and oauth2-proxy charts
  are installed. Pin them once it works so an apply cannot upgrade by
  surprise.
- **Local HTTP testing** only works with `localhost` for most identity
  providers, and the cookie is unprotected. Never run that way for real use.
- **kind has no load balancer.** Use `NodePort` there, as the local example
  does, or the gateway's address stays `<pending>`.

## Troubleshooting

| Symptom                                         | Likely cause and fix                                                     |
|-------------------------------------------------|--------------------------------------------------------------------------|
| Identity provider says "redirect URI mismatch"  | Register the exact `redirect_uri` from `terraform output`.               |
| Browser loops between your site and the provider| Cookie not kept: you are on `http` with `tls_enabled = true`, or several hosts without `cookie_domain`. |
| `RBAC: access denied` (403) on every page       | The gateway cannot reach oauth2-proxy. Check `kubectl get pods -n oauth2-proxy` and that `service` and `port` in `values/istiod.yaml` match. |
| 500 after signing in, oauth2-proxy logs mention email | The provider sent no usable e-mail claim. Set `oidc-email-claim` or `insecure-oidc-allow-unverified-email` in `oidc_extra_args`. |
| oauth2-proxy pod keeps restarting               | Wrong issuer URL (it must serve `/.well-known/openid-configuration`), or the pod cannot reach the provider. See `kubectl logs -n oauth2-proxy deploy/oauth2-proxy`. |
| Certificate warning in the browser              | The TLS secret is missing, in the wrong namespace, or for another host. It must be in `istio-ingress`. |
| No sign-in asked at all                         | The host you opened is not in `hosts`, or the path is in `public_paths`. |
| 404 after signing in                            | No VirtualService routes that host. Deploy the demo app or add your own. |
| `terraform apply` hangs on the gateway          | `LoadBalancer` on a cluster without one. Use `gateway_service_type = "NodePort"`. |
| Gateway `EXTERNAL-IP` is `<pending>`            | Same cause, or the cloud is still creating the load balancer (wait a few minutes). |

Useful commands:

    kubectl get pods -n istio-system
    kubectl get pods -n istio-ingress
    kubectl logs -n oauth2-proxy deploy/oauth2-proxy
    kubectl logs -n istio-ingress deploy/istio-ingress
    kubectl get gateway,virtualservice,authorizationpolicy -A

## Removing it

    terraform destroy            # if you installed with Terraform
    helm/uninstall.sh            # if you installed with the script
