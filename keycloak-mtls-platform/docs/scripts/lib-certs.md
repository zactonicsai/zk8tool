# `scripts/lib/certs.sh`

Implements `platform.sh certs`. Concepts are explained in
[certificates and mTLS](../03-certificates-and-mtls.md); this page documents
the script.

## Flow of `certs_main`

1. Parse options (`--only`, `--force`, `--force-ca`, `--pkcs12`, `--verify`).
2. `--verify`: run `certs_verify` and stop.
3. Create `CERT_DIR` (mode 700).
4. Create the CA if it is missing (or `--force-ca`); warn if it expires soon.
5. For each selected leaf ask `_certs_issue_reason`; issue when it returns a reason.
6. Optionally write PKCS#12 stores.
7. Verify everything that was selected; fail the command if verification fails.

## Functions

| Function | Purpose |
|---|---|
| `certs_create_ca` | Self-signed root: `basicConstraints=critical,CA:TRUE,pathlen:0`, `keyUsage=critical,keyCertSign,cRLSign`, SHA-384. |
| `certs_create_leaf NAME` | New key, CSR, certificate signed by the CA with a random 128-bit serial; files are created in a temp directory and moved into place only when complete. |
| `_certs_profile NAME` | Key algorithm, key usage, extended key usage and lifetime per certificate. |
| `_certs_sans NAME` | SAN list: Service names for all DNS forms, `localhost`, `127.0.0.1`, the public URL's host, `CERT_EXTRA_SANS_*`. |
| `_certs_fingerprint NAME` | Subject + profile + SANs the certificate *should* have; stored as `cert.info` to detect configuration drift. The lifetime is not part of it. |
| `_certs_issue_reason NAME FORCE` | Returns why a leaf must be issued: `forced`, `missing`, `not signed by the current CA`, `subject / SAN / profile changed`, `expires within N days`; empty when up to date. The SAML certificate only warns on expiry. |
| `certs_verify [NAMES…]` / `certs_verify_leaf` | Chain, key/certificate match (public key hashes), expiry, `openssl verify -purpose sslserver/sslclient`, key mode 600. |
| `certs_write_pkcs12 NAME` | `keystore.p12` (key + chain) and `truststore.p12` (CA) with a random password file; the password is passed by file, never as an argument. |
| `certs_require NAMES…` | Used by `build`, `secrets`: fail with "Run: platform.sh certs" when material is missing. |
| `certs_subject_dn NAME` | RFC 2253 subject, e.g. `CN=test-client,OU=Platform,O=Example Corp,C=US`. |
| `certs_der_b64 FILE` | Single-line base64 DER, the format of Keycloak's `saml.signing.certificate`. |
| `certs_path NAME FILE` | Path helper. |

## Portability

Only widely supported openssl features are used (`genpkey`, `req`,
`x509 -req -extfile`, `verify`, `pkcs12`), with extensions supplied through
generated config files rather than newer command-line flags, so OpenSSL
1.1.1+, 3.x and LibreSSL 3+ work.

## Adding a certificate

1. Add the name to `CERT_LEAVES`.
2. Add its profile in `_certs_profile` and its SANs in `_certs_sans`.
3. If a workload uses it: add the Secret mount in the chart and, for
   cert-manager mode, a `Certificate` in
   `templates/certificates/certificates.yaml`.
4. Add a bats test in `tests/scripts/certs.bats`.

## Tests

`tests/scripts/certs.bats` (24 tests): chain and profiles of each
certificate, PKCS#8 + permissions, CA constraints, custom subject, extra
SANs, RSA mode, idempotency, `--force`, `--only`, SAN drift, renewal window,
`--force-ca`, each `--verify` failure mode, PKCS#12, dry-run.
