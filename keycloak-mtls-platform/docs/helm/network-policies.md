# Network policies

Files: `templates/keycloak/networkpolicy.yaml`,
`templates/app/networkpolicy.yaml`, `templates/tests/networkpolicy.yaml`.
Rendered when `networkPolicy.enabled` (default).

Each policy selects one workload and sets `policyTypes: [Ingress, Egress]`,
so everything not listed is denied in both directions.

> NetworkPolicies need a CNI that enforces them (on AKS: Azure CNI powered
> by Cilium, Azure NPM or Calico). Without one they are accepted but have no effect.

## Allowed flows

```
test pod ──8443,9000──▶ Keycloak ◀──8443── app ◀──8443,9443── test pod
                         │  ▲
              7800,57800 └──┘ (Keycloak pods among themselves)
```

### Keycloak

| Direction | Peer | Ports | Why |
|---|---|---|---|
| ingress | app pods, test pod, `keycloak.networkPolicy.extraIngress` | 8443 | OIDC / SAML back-channel, token requests |
| ingress | test pod | 9000 | health check of the test |
| ingress | Keycloak pods | 7800, 57800 | cluster traffic |
| egress | anywhere | 53 UDP/TCP | DNS |
| egress | Keycloak pods | 7800, 57800 | cluster traffic |
| egress | anywhere | database port | only with an external database; the port is `keycloak.database.port` or the vendor default |
| egress | `keycloak.networkPolicy.extraEgress` | | LDAP, SMTP, external identity providers, … |

### Spring app

| Direction | Peer | Ports | Why |
|---|---|---|---|
| ingress | test pod, `app.networkPolicy.extraIngress` | 8443 | API and browser traffic |
| ingress | test pod | 9443 | health check of the test |
| egress | anywhere | 53 UDP/TCP | DNS |
| egress | Keycloak pods | 8443 | token, JWKS, userinfo, SAML metadata |
| egress | `app.networkPolicy.extraEgress` | | anything else the app must reach |

### Test pod

No ingress. Egress: DNS; Keycloak 8443 and 9000; app 8443 and 9443.

Kubelet probes are not affected: traffic from the node to its own pods is
allowed by the common CNIs.

## Letting real clients in

By default **nothing outside the release** can reach Keycloak or the app.
Choose one:

**Name the peers** (preferred), for example the ingress controller's namespace:

```yaml
keycloak:
  networkPolicy:
    extraIngress:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress
app:
  networkPolicy:
    extraIngress:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress
      - namespaceSelector:              # an API consumer in another namespace
          matchLabels:
            kubernetes.io/metadata.name: orders
        podSelector:
          matchLabels:
            app: orders-service
```

**Or open port 8443 to any source**:

```yaml
networkPolicy:
  allowExternalHttps: true
```

This removes the `from` restriction on 8443 for Keycloak and the app; the
management ports stay restricted. Authentication still applies (mTLS and
tokens), but prefer named peers.

## Adding egress

```yaml
keycloak:
  networkPolicy:
    extraEgress:
      - ports:
          - {port: 636, protocol: TCP}      # LDAPS
        to:
          - ipBlock: {cidr: 10.20.0.0/16}
```

## Monitoring

To scrape Keycloak metrics (`:9000/metrics`), add the monitoring namespace
as a peer. The built-in rule for 9000 only lists the test pod, so add a
separate policy in your monitoring setup or extend the template.

## Tests

`tests/networkpolicy_test.yaml` (12 cases): default deny in both directions,
exact peers and ports per workload, database egress by vendor and explicit
port, extra peers and rules, `allowExternalHttps`, test pod isolation, and
no policies when disabled.
