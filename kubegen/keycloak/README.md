# Keycloak, with Istio SSO sign-in

Installs [Keycloak](https://www.keycloak.org/) as the identity provider
inside your cluster and wires the Istio gateway's sign-in (see `../istio`) to
it. One script does both, on whatever cluster your current `kubectl` context
points at.

    browser --> Istio gateway --"signed in?"--> oauth2-proxy --> Keycloak (in the cluster)
                     |                                              ^
                     +--> your app                                  |
                     +--> keycloak.<your domain> (login pages) -----+

## What is in this directory

| Path                    | Purpose                                                        |
|-------------------------|----------------------------------------------------------------|
| `install.sh`            | Installs Istio with sign-in **and** Keycloak on the current context |
| `uninstall.sh`          | Removes Keycloak (optionally its data, optionally Istio too)   |
| `keycloak.env.example`  | Settings file for `install.sh`; copy it to `keycloak.env`      |
| `chart/`                | Helm chart: Keycloak, PostgreSQL, the SSO realm, the Istio route |
| `chart/values.yaml`     | Every chart setting, with explanations                         |

## Quick start: local test cluster

You need `helm`, `kubectl` and `openssl`; the script prints download links
for any that are missing.

1. Create a kind cluster that maps `localhost:8080` to node port `30080`.
   `podman/kind-podman.yaml` in this project does exactly that:

       ./bin/kubegen -f podman/kind-podman.yaml && ./create-dev-podman.sh

2. Check which cluster you are about to install on:

       kubectl config current-context

3. Install:

       cd keycloak
       ./install.sh

   The script shows the context and the addresses it will use and asks
   before changing anything (`./install.sh -y` skips the question). The
   first Keycloak start takes a few minutes.

4. Try it:

   | Open                                    | Sign in as      |
   |-----------------------------------------|-----------------|
   | `http://localhost:8080/headers`         | `demo` / `demo` |
   | `http://keycloak.localhost:8080/admin`  | `admin` / `admin` |

   The first address sends you to Keycloak's login page, then back to a test
   app that prints your request headers, including `X-Auth-Request-Email`.

Browsers resolve `keycloak.localhost` to your own machine without any setup.
Command-line tools may not; use a browser to test.

## Installing on a real cluster

    cd keycloak
    cp keycloak.env.example keycloak.env

Edit `keycloak.env`, using the "A real cluster" block:

| Setting                   | Set it to                                             |
|---------------------------|-------------------------------------------------------|
| `APP_HOST`                | Host of the app behind sign-in, e.g. `app.example.com`|
| `KEYCLOAK_HOST`           | Host for Keycloak, e.g. `keycloak.example.com`        |
| `TLS_ENABLED`             | `true`                                                |
| `TLS_SECRET_NAME`         | A `kubernetes.io/tls` secret in `istio-ingress` whose certificate covers **both** hosts |
| `EXTERNAL_PORT`           | empty                                                 |
| `GATEWAY_SERVICE_TYPE`    | `LoadBalancer`                                        |
| `KEYCLOAK_ADMIN_PASSWORD` | A long random password                                |
| `DEMO_USER`               | `false`                                               |

Then:

    kubectl create namespace istio-ingress
    kubectl create secret tls sso-gateway-tls -n istio-ingress --cert=cert.pem --key=key.pem
    ./install.sh
    kubectl get service istio-ingress -n istio-ingress      # point DNS for both hosts here

Prefer Terraform? `../istio/terraform/examples/keycloak-in-cluster.tfvars.example`
installs the same thing, including this chart.

## About `admin` / `admin`

The chart's default administrator is `admin` with password `admin`, as
requested. Please treat that as a test-cluster setting only:

- Whoever can open the admin console with it controls every login in the
  realm: they can add users, reset passwords and read client secrets.
- On a real cluster set `KEYCLOAK_ADMIN_PASSWORD` before the first install.
  The script prints a warning when the password is still `admin`.
- Keycloak marks this first admin as temporary. Create a personal admin
  user in the `master` realm, sign in with it, and delete `admin`.
- The password is only applied when no admin exists yet. To change it
  later, change it in the console.

## What the chart does, and why

| Practice                         | How the chart does it                                           |
|----------------------------------|-----------------------------------------------------------------|
| Official image, production mode  | `quay.io/keycloak/keycloak`, started with `start` (not `start-dev`) |
| Real database                    | PostgreSQL, not the built-in development database               |
| Fixed public address             | `KC_HOSTNAME` set to the public URL                             |
| TLS at the edge                  | The Istio gateway ends TLS; Keycloak trusts its `X-Forwarded-*` headers |
| Health checks                    | Startup, readiness and liveness probes on the management port (9000), which is not exposed |
| Locked-down container            | Non-root, no privilege escalation, all capabilities dropped     |
| Secrets                          | Admin, database and client secrets live in Kubernetes Secrets   |
| Current admin bootstrap          | `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`   |
| Repeatable realm                 | Realm `sso` with the `oauth2-proxy` client is imported on first start |
| PKCE                             | The client requires it and oauth2-proxy is configured to use it |

What is deliberately simple, and what to change for production:

| Development default                 | For production                                              |
|-------------------------------------|-------------------------------------------------------------|
| `admin` / `admin`                   | Strong password; then personal admin accounts               |
| Bundled single PostgreSQL pod       | A managed or replicated PostgreSQL: `database.host=...`, `postgresql.enabled=false` |
| Database password `keycloak`        | `database.password=...`                                     |
| One Keycloak pod                    | `replicas: 2` or more                                       |
| Image tag `26.6` (latest patch)     | An exact version, e.g. `26.6.4`                             |
| `demo` / `demo` user                | `DEMO_USER=false`                                           |
| Plain HTTP on localhost             | HTTPS with a real certificate                               |

## How it connects to Istio

`install.sh` runs `../istio/helm/install.sh` with Keycloak's details, which:

- adds the Keycloak host to the gateway as a **public host**, so its login
  pages are reachable without already being signed in;
- points oauth2-proxy at Keycloak. Browsers are sent to Keycloak's public
  address, while oauth2-proxy itself fetches tokens and signing keys from
  `keycloak.keycloak.svc.cluster.local` over the cluster network. This is
  why it also works on a local cluster and with private certificates;
- gives oauth2-proxy and the Keycloak realm the same client ID and secret.
  The secret is generated on the first run and reused afterwards.

The chart then adds a route (an Istio `VirtualService`) from the Keycloak
host to the Keycloak service.

## Everyday tasks

| Task                         | How                                                              |
|------------------------------|------------------------------------------------------------------|
| Add a user                   | Admin console > realm `sso` > Users > Add user, then set a password under Credentials |
| Let people in by group       | Add groups in the realm; your app reads `X-Auth-Request-Groups` once a groups mapper is added to the client |
| See Keycloak's logs          | `kubectl logs -n keycloak keycloak-0`                            |
| See sign-in logs             | `kubectl logs -n oauth2-proxy deploy/oauth2-proxy`               |
| Upgrade Keycloak             | Set `KEYCLOAK_IMAGE_TAG` and run `./install.sh` again            |
| Keycloak only (Istio exists) | `INSTALL_ISTIO=false ./install.sh`                               |

## Gotchas

- **The script installs on the current context.** Check
  `kubectl config current-context` first; the script shows it and asks.
- **The realm is imported once.** Changing the realm name, client or demo
  user in the settings later has no effect on an existing realm. Change it
  in the admin console, or `./uninstall.sh --purge` and install again.
- **Keep the client secret stable.** The script reuses the one stored in
  the cluster. If you set `OIDC_CLIENT_SECRET` to a new value later,
  oauth2-proxy and Keycloak disagree and sign-in fails.
- **Signing out of the app is not signing out of Keycloak.**
  `/oauth2/sign_out` ends the gateway session, but Keycloak still remembers
  you, so the next visit signs you straight back in. End the Keycloak
  session from its account page, or close the browser.
- **One certificate, two hosts.** With HTTPS the gateway's TLS secret must
  be valid for both the app host and the Keycloak host (a wildcard or a
  certificate listing both).
- **Uninstalling keeps the database** unless you pass `--purge`. Installing
  again then finds the old realm and users, and the old admin password.
- **First start is slow.** Keycloak builds its configuration and creates
  the database tables; allow five minutes or more on a small machine.
- **The bundled PostgreSQL has no backups.** Losing its volume loses every
  user and setting.
- **Rootless Podman and low ports.** The local setup uses port 8080 for
  that reason.

## Troubleshooting

| Symptom                                               | Likely cause and fix                                              |
|-------------------------------------------------------|-------------------------------------------------------------------|
| `install.sh` times out waiting for Keycloak           | Look at `kubectl get pods -n keycloak` and `kubectl logs -n keycloak keycloak-0`. Usually the database pod is not ready (no storage class for its volume) or the node is short of memory (Keycloak asks for 1 GiB). |
| `keycloak-postgres-0` stays `Pending`                 | The cluster has no default storage class. Set `postgresql.storageClassName` in the chart values. |
| Browser cannot open `keycloak.localhost:8080`         | The kind cluster does not map port 8080 to node port 30080, or your browser does not resolve `*.localhost`. Recreate the cluster from `podman/kind-podman.yaml`. |
| Keycloak page says "Invalid parameter: redirect_uri"  | The app address changed after the realm was created. Add the new `.../oauth2/callback` address to the client's valid redirect URIs in the admin console. |
| Back at the app with a 500 after logging in           | oauth2-proxy could not exchange the code: client secret mismatch, or Keycloak not reachable inside the cluster. Check `kubectl logs -n oauth2-proxy deploy/oauth2-proxy`. |
| "Invalid client or Invalid client credentials"        | Client secret mismatch; see the gotcha above. Copy the secret from the client's Credentials tab into the `oauth2-proxy-credentials` secret, or purge and reinstall. |
| Token rejected: issuer does not match                 | Keycloak's public URL (`externalUrl`) differs from the address in the browser, e.g. a missing port. Both come from `KEYCLOAK_HOST`, `TLS_ENABLED` and `EXTERNAL_PORT`. |
| Admin login `admin` / `admin` refused                 | An admin already existed from an earlier install with another password (the database was kept). Use that password, or `./uninstall.sh --purge` and reinstall. |
| Keycloak says "HTTPS required"                        | Plain HTTP from a public address. Use HTTPS (`TLS_ENABLED=true`) outside a local cluster. |
| Sign-in page loads without styling                    | The Keycloak host is not served by the gateway. It must be in the gateway's public hosts; rerun `./install.sh`. |

## Removing it

    ./uninstall.sh                 # Keycloak only, database kept
    ./uninstall.sh --purge         # Keycloak and all its data
    ./uninstall.sh --purge --with-istio    # everything
