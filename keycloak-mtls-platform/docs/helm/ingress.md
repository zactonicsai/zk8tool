# Exposing Keycloak and the app

Files: `templates/keycloak/ingress.yaml`, `templates/app/ingress.yaml`
(both optional, off by default).

By default the release is reachable only inside the cluster, which is all
that service-to-service use and the test pod need. To let browsers in you
need four things.

## 1. Public URLs

```yaml
keycloak:
  publicUrl: https://sso.example.com
  proxyHeaders: xforwarded          # the proxy sets X-Forwarded-* headers
app:
  publicUrl: https://app.example.com
  forwardHeadersStrategy: native
```

(or `KC_PUBLIC_URL` / `APP_PUBLIC_URL` in `platform.env`, which also adds
the host names to the certificate SANs).

Effects: tokens get the public issuer, redirect URIs and the SAML entity ID
use the public app URL, Keycloak serves in-cluster callers on the Service
URL (`hostname-backchannel-dynamic`).

Set public URLs **before the first install**: the realm import bakes the
app URL into redirect URIs and the SAML client. Changing it later means
updating those clients in Keycloak ([realm](../05-keycloak-realm.md#changing-the-realm-after-the-first-start)).

## 2. An Ingress (or Gateway) that re-encrypts

Both backends speak **HTTPS only**. The proxy must connect to the backend
with TLS; ideally it also verifies the backend certificate against the
platform CA.

```yaml
keycloak:
  ingress:
    enabled: true
    className: <your ingress class>
    host: sso.example.com
    tlsSecretName: sso-example-com-tls      # the public certificate
    annotations: {}                          # controller specific, see below
```

The templates create a plain `networking.k8s.io/v1` Ingress routing `/` to
the Service's `https` port. How to say "the backend is HTTPS" depends on the
controller, so it is left to `annotations`, for example:

| Controller | Setting |
|---|---|
| NGINX Ingress Controller (F5) | `nginx.org/ssl-services: <service name>` |
| HAProxy Ingress | `haproxy.org/server-ssl: "true"` |
| Traefik | `traefik.ingress.kubernetes.io/service.serversscheme: https` (on the Service) |
| Azure Application Gateway for Containers / Gateway API | a `BackendTLSPolicy` for the Service instead of an Ingress |

Check your controller's documentation for backend CA verification and for
presenting a client certificate to the backend.

With the Gateway API, disable the chart's Ingress and create an `HTTPRoute`
to the Service port `https` plus a `BackendTLSPolicy` that trusts the
platform CA.

## 3. NetworkPolicy peers

Allow the proxy's namespace ([network policies](network-policies.md#letting-real-clients-in)).

## 4. Session affinity for the app

With `app.replicas > 1`, enable cookie-based affinity in the proxy: browser
sessions are kept in memory per pod.

## Client certificates through a proxy

A TLS-terminating proxy ends the client's TLS session, so the backend no
longer sees the caller's certificate. Consequences:

- **Browser logins**: unaffected (no client certificates involved).
- **App → Keycloak back-channel**: unaffected, it stays in-cluster.
- **External API clients using mTLS**: either expose the app with **TLS
  passthrough** (the proxy forwards the TLS stream; the app terminates it
  and sees the certificate) or with a `LoadBalancer` Service, or keep such
  clients inside the cluster.
- **External OAuth clients authenticating to Keycloak with a certificate**:
  use passthrough as well, or configure the proxy to forward the client
  certificate in a header and Keycloak's X.509 lookup provider to read it.

## Keycloak admin console

Do not publish `/admin` to the internet. Restrict it at the proxy (path
rules, IP allow-list) or serve the admin console on a separate internal
host name (`hostname-admin`).

## Without an ingress controller

- `kubectl port-forward svc/iam-keycloak 8443:8443` for administration
  (the certificate includes `localhost`).
- `keycloak.service.type: LoadBalancer` (with an internal load balancer
  annotation on AKS) exposes the HTTPS port directly, preserving mTLS end to end.
