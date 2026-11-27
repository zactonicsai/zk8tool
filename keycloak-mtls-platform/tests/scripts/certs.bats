#!/usr/bin/env bats
# Certificate creation (scripts/lib/certs.sh). Uses the real openssl.

load test_helper

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

CERTS() { printf '%s/certs' "$SANDBOX"; }

@test "certs creates a CA and the four leaf certificates" {
  run platform certs
  [ "$status" -eq 0 ]
  [ -s "$(CERTS)/ca/ca.crt" ]
  [ -s "$(CERTS)/ca/ca.key" ]
  for name in keycloak spring-app test-client saml-sp; do
    [ -s "$(CERTS)/${name}/tls.crt" ]
    [ -s "$(CERTS)/${name}/tls.key" ]
    [ -s "$(CERTS)/${name}/ca.crt" ]
    run openssl verify -CAfile "$(CERTS)/ca/ca.crt" "$(CERTS)/${name}/tls.crt"
    [ "$status" -eq 0 ]
  done
}

@test "private keys are unencrypted PKCS#8 with mode 600 in 700 directories" {
  platform certs
  for name in ca/ca.key keycloak/tls.key spring-app/tls.key test-client/tls.key saml-sp/tls.key; do
    [ "$(file_mode "$(CERTS)/${name}")" = "600" ]
    run head -n 1 "$(CERTS)/${name}"
    [ "$output" = "-----BEGIN PRIVATE KEY-----" ]
  done
  [ "$(file_mode "$(CERTS)")" = "700" ]
  [ "$(file_mode "$(CERTS)/ca")" = "700" ]
}

@test "the CA may only sign leaf certificates" {
  platform certs
  run openssl x509 -in "$(CERTS)/ca/ca.crt" -noout -text
  [[ "$output" == *"CA:TRUE, pathlen:0"* ]]
  [[ "$output" == *"Certificate Sign, CRL Sign"* ]]
  [[ "$output" == *"CN = iam-platform Root CA"* || "$output" == *"CN=iam-platform Root CA"* ]]
}

@test "subjects follow the configured organisation" {
  set_config CERT_ORG '"Acme Corp"'
  set_config CERT_OU Identity
  set_config CERT_COUNTRY DE
  platform certs
  run openssl x509 -in "$(CERTS)/test-client/tls.crt" -noout -subject -nameopt RFC2253
  [ "$output" = "subject=CN=test-client,OU=Identity,O=Acme Corp,C=DE" ]
}

@test "the Keycloak certificate is a server certificate for every service name" {
  platform certs
  run cert_text keycloak
  [[ "$output" == *"DNS:iam-keycloak,"* ]]
  [[ "$output" == *"DNS:iam-keycloak.iam,"* ]]
  [[ "$output" == *"DNS:iam-keycloak.iam.svc,"* ]]
  [[ "$output" == *"DNS:iam-keycloak.iam.svc.cluster.local"* ]]
  [[ "$output" == *"DNS:localhost"* ]]
  [[ "$output" == *"IP Address:127.0.0.1"* ]]
  [[ "$output" == *"TLS Web Server Authentication"* ]]
  [[ "$output" != *"TLS Web Client Authentication"* ]]
  [[ "$output" == *"CA:FALSE"* ]]
}

@test "the app certificate works as server and as client" {
  platform certs
  run cert_text spring-app
  [[ "$output" == *"DNS:iam-spring-app.iam.svc.cluster.local"* ]]
  [[ "$output" == *"TLS Web Server Authentication, TLS Web Client Authentication"* ]]
}

@test "the test client certificate is client-only" {
  platform certs
  run cert_text test-client
  [[ "$output" == *"TLS Web Client Authentication"* ]]
  [[ "$output" != *"TLS Web Server Authentication"* ]]
}

@test "the SAML signing certificate is RSA even when TLS uses EC" {
  platform certs
  run cert_text saml-sp
  [[ "$output" == *"Public Key Algorithm: rsaEncryption"* ]]
  [[ "$output" == *"Digital Signature"* ]]
  [[ "$output" != *"Subject Alternative Name"* ]]
  run cert_text keycloak
  [[ "$output" == *"Public Key Algorithm: id-ecPublicKey"* ]]
}

@test "extra SANs, public hostnames and other namespaces end up in the certificate" {
  set_config CERT_EXTRA_SANS_KEYCLOAK "login.example.com, 10.0.0.7"
  set_config KC_PUBLIC_URL https://sso.example.com
  set_config K8S_NAMESPACE identity
  set_config HELM_RELEASE prod
  platform certs
  run cert_text keycloak
  [[ "$output" == *"DNS:prod-keycloak.identity.svc.cluster.local"* ]]
  [[ "$output" == *"DNS:login.example.com"* ]]
  [[ "$output" == *"DNS:sso.example.com"* ]]
  [[ "$output" == *"IP Address:10.0.0.7"* ]]
}

@test "RSA can be selected for the TLS certificates" {
  set_config CERT_KEY_ALG rsa
  set_config CERT_RSA_BITS 2048
  platform certs
  run cert_text keycloak
  [[ "$output" == *"Public Key Algorithm: rsaEncryption"* ]]
  [[ "$output" == *"Digital Signature, Key Encipherment"* ]]
}

@test "a second run changes nothing" {
  platform certs
  before="$(cert_serial keycloak)$(cert_serial saml-sp)$(openssl x509 -in "$(CERTS)/ca/ca.crt" -noout -serial)"
  run platform certs
  [ "$status" -eq 0 ]
  [[ "$output" != *"issuing"* ]]
  after="$(cert_serial keycloak)$(cert_serial saml-sp)$(openssl x509 -in "$(CERTS)/ca/ca.crt" -noout -serial)"
  [ "$before" = "$after" ]
}

@test "--force re-issues the leaves but keeps the CA" {
  platform certs
  ca_before="$(openssl x509 -in "$(CERTS)/ca/ca.crt" -noout -serial)"
  leaf_before="$(cert_serial keycloak)"
  run platform certs --force
  [ "$status" -eq 0 ]
  [ "$ca_before" = "$(openssl x509 -in "$(CERTS)/ca/ca.crt" -noout -serial)" ]
  [ "$leaf_before" != "$(cert_serial keycloak)" ]
}

@test "--only limits which certificates are touched" {
  platform certs
  app_before="$(cert_serial spring-app)"
  kc_before="$(cert_serial keycloak)"
  run platform certs --only keycloak --force
  [ "$status" -eq 0 ]
  [ "$kc_before" != "$(cert_serial keycloak)" ]
  [ "$app_before" = "$(cert_serial spring-app)" ]
}

@test "--only rejects unknown names" {
  run platform certs --only keycloak,bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown certificate 'bogus'"* ]]
}

@test "a changed SAN list triggers re-issuing of that certificate only" {
  platform certs
  kc_before="$(cert_serial keycloak)"
  client_before="$(cert_serial test-client)"
  set_config CERT_EXTRA_SANS_KEYCLOAK new.example.com
  run platform certs
  [ "$status" -eq 0 ]
  [[ "$output" == *"keycloak: subject / SAN / profile changed"* ]]
  [ "$kc_before" != "$(cert_serial keycloak)" ]
  [ "$client_before" = "$(cert_serial test-client)" ]
}

@test "certificates inside the renewal window are re-issued, except the SAML one" {
  set_config CERT_LEAF_DAYS 10
  set_config CERT_SAML_DAYS 10
  set_config CERT_RENEW_BEFORE_DAYS 5
  platform certs
  kc_before="$(cert_serial keycloak)"
  saml_before="$(cert_serial saml-sp)"
  # Same certificates, but now everything expiring within 20 days counts as due.
  set_config CERT_LEAF_DAYS 90
  set_config CERT_SAML_DAYS 10
  set_config CERT_RENEW_BEFORE_DAYS 20
  run platform certs --only keycloak,saml-sp
  [ "$status" -eq 0 ]
  [[ "$output" == *"keycloak: expires within 20 days -> issuing"* ]]
  [ "$kc_before" != "$(cert_serial keycloak)" ]
  [ "$saml_before" = "$(cert_serial saml-sp)" ]
  [[ "$output" == *"saml-sp expires within 20 days; rotate it deliberately"* ]]
}

@test "--force-ca replaces the CA and every leaf" {
  platform certs
  ca_before="$(openssl x509 -in "$(CERTS)/ca/ca.crt" -noout -serial)"
  leaf_before="$(cert_serial test-client)"
  run platform certs --force-ca
  [ "$status" -eq 0 ]
  [[ "$output" == *"replacing the CA"* ]]
  [ "$ca_before" != "$(openssl x509 -in "$(CERTS)/ca/ca.crt" -noout -serial)" ]
  [ "$leaf_before" != "$(cert_serial test-client)" ]
  run platform certs --verify
  [ "$status" -eq 0 ]
}

@test "--verify succeeds on fresh certificates and changes nothing" {
  platform certs
  before="$(cert_serial keycloak)"
  run platform certs --verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"keycloak: OK"* ]]
  [ "$before" = "$(cert_serial keycloak)" ]
}

@test "--verify detects a key that does not match its certificate" {
  platform certs
  cp "$(CERTS)/spring-app/tls.key" "$(CERTS)/keycloak/tls.key"
  run platform certs --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"keycloak: private key does not match certificate"* ]]
}

@test "--verify detects a certificate from another CA" {
  platform certs
  cp -R "$(CERTS)" "${SANDBOX}/other"
  platform certs --force-ca
  cp "${SANDBOX}/other/test-client/tls.crt" "${SANDBOX}/other/test-client/tls.key" "$(CERTS)/test-client/"
  run platform certs --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"test-client: does not chain to"* ]]
}

@test "--verify detects world-readable private keys" {
  platform certs
  chmod 644 "$(CERTS)/keycloak/tls.key"
  run platform certs --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"must have mode 600"* ]]
}

@test "--verify without certificates explains what to do" {
  run platform certs --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"no CA in"* ]]
}

@test "--pkcs12 adds keystores protected by a generated password" {
  if ! command -v keytool >/dev/null; then skip "keytool not installed"; fi
  run platform certs --pkcs12 --only spring-app
  [ "$status" -eq 0 ]
  [ -s "$(CERTS)/spring-app/keystore.p12" ]
  [ -s "$(CERTS)/spring-app/truststore.p12" ]
  [ "$(file_mode "$(CERTS)/spring-app/keystore.password")" = "600" ]
  run openssl pkcs12 -in "$(CERTS)/spring-app/keystore.p12" -passin "file:$(CERTS)/spring-app/keystore.password" -nokeys
  [ "$status" -eq 0 ]
  [[ "$output" == *"spring-app"* ]]
}

@test "dry-run creates nothing" {
  run platform --dry-run certs
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] create CA"* ]]
  [[ "$output" == *"[dry-run] issue certificate keycloak"* ]]
  [ ! -e "$(CERTS)" ]
}
