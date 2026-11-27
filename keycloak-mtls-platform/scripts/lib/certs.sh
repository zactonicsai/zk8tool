#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/lib/certs.sh - private CA and leaf certificates for mTLS.
#
# Layout written under ${CERT_DIR}:
#   ca/ca.crt  ca/ca.key                  root CA (key never leaves this dir)
#   keycloak/{tls.crt,tls.key,ca.crt}     server certificate
#   spring-app/{tls.crt,tls.key,ca.crt}   server + client certificate
#   test-client/{tls.crt,tls.key,ca.crt}  client certificate
#   saml-sp/{tls.crt,tls.key,ca.crt}      RSA SAML request-signing certificate
#
# All private keys are unencrypted PKCS#8 PEM with mode 0600; that is the one
# format Keycloak, Spring Boot and the plain-JDK test client all read.
# Docs: docs/scripts/lib-certs.md and docs/03-certificates-and-mtls.md
# =============================================================================

if [[ -n "${__PLATFORM_CERTS_SH:-}" ]]; then return 0; fi
__PLATFORM_CERTS_SH=1

CERT_LEAVES=(keycloak spring-app test-client saml-sp)

certs_usage() {
  cat <<'EOF'
Usage: platform.sh certs [options]

Create (or renew) the private CA and the leaf certificates used for mTLS.
Existing material is kept unless it is missing, about to expire, or its
subjectAltNames no longer match the configuration.

Options:
  --only NAMES     Comma separated subset: keycloak,spring-app,test-client,saml-sp
  --force          Re-issue the selected leaf certificates (new keys)
  --force-ca       Re-create the CA as well (invalidates EVERY certificate)
  --pkcs12         Also write keystore.p12 / truststore.p12 + keystore.password
  --verify         Only verify what exists (chain, key match, expiry); no changes
  -h, --help       Show this help
EOF
}

# certs_path NAME FILE - e.g. certs_path keycloak tls.crt
certs_path() { printf '%s/%s/%s' "$CERT_DIR" "$1" "$2"; }

# certs_subject_dn NAME - RFC 2253 subject, the form Keycloak's X.509 client
# authenticator compares against.
certs_subject_dn() {
  printf 'CN=%s,OU=%s,O=%s,C=%s' "$1" "$CERT_OU" "$CERT_ORG" "$CERT_COUNTRY"
}

# certs_der_b64 FILE - certificate as single-line base64 DER (what Keycloak
# stores in the SAML client attribute "saml.signing.certificate").
certs_der_b64() {
  openssl x509 -in "$1" -outform DER | openssl base64 -A
}

_certs_openssl_subject() {
  printf '/C=%s/O=%s/OU=%s/CN=%s' "$CERT_COUNTRY" "$CERT_ORG" "$CERT_OU" "$1"
}

# _certs_genkey ALG OUT [ca] - unencrypted PKCS#8 key, created with umask 077.
_certs_genkey() {
  local alg=$1 out=$2 strength=${3:-leaf}
  (
    umask 077
    case "$alg" in
      ec)
        local curve=$CERT_EC_CURVE
        if [[ "$strength" == "ca" ]]; then curve=secp384r1; fi
        openssl genpkey -algorithm EC -pkeyopt "ec_paramgen_curve:${curve}" -out "$out"
        ;;
      rsa)
        local bits=$CERT_RSA_BITS
        if [[ "$strength" == "ca" ]]; then bits=4096; fi
        openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${bits}" -out "$out"
        ;;
      *) die "certs: unsupported key algorithm '$alg'" 2 ;;
    esac
  ) 2>/dev/null || die "certs: key generation failed for ${out}"
  chmod 600 "$out"
}

# _certs_profile NAME - prints "<alg> <keyUsage> <extendedKeyUsage|-> <days>".
_certs_profile() {
  local ku="digitalSignature"
  if [[ "$CERT_KEY_ALG" == "rsa" ]]; then ku="digitalSignature, keyEncipherment"; fi
  case "$1" in
    keycloak) printf '%s|%s|%s|%s' "$CERT_KEY_ALG" "$ku" "serverAuth" "$CERT_LEAF_DAYS" ;;
    spring-app) printf '%s|%s|%s|%s' "$CERT_KEY_ALG" "$ku" "serverAuth, clientAuth" "$CERT_LEAF_DAYS" ;;
    test-client) printf '%s|%s|%s|%s' "$CERT_KEY_ALG" "$ku" "clientAuth" "$CERT_LEAF_DAYS" ;;
    # Keycloak only supports RSA (and DSA) signatures for SAML clients.
    saml-sp) printf '%s|%s|%s|%s' "rsa" "digitalSignature" "-" "$CERT_SAML_DAYS" ;;
    *) die "certs: unknown certificate '$1'" 2 ;;
  esac
}

# _certs_sans NAME - one SAN per line as "DNS:<name>" or "IP:<addr>".
_certs_sans() {
  local name=$1 svc="" extra="" public_host="" item
  local re_ip='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  case "$name" in
    keycloak)
      svc=$KC_SERVICE_NAME
      extra=$CERT_EXTRA_SANS_KEYCLOAK
      public_host=$(url_host "$KC_PUBLIC_URL")
      ;;
    spring-app)
      svc=$APP_SERVICE_NAME
      extra=$CERT_EXTRA_SANS_APP
      public_host=$(url_host "$APP_PUBLIC_URL")
      ;;
    test-client)
      printf 'DNS:%s\n' "$CLIENT_NAME"
      return 0
      ;;
    saml-sp) return 0 ;;
  esac
  {
    printf 'DNS:%s\n' "$svc"
    printf 'DNS:%s.%s\n' "$svc" "$K8S_NAMESPACE"
    printf 'DNS:%s.%s.svc\n' "$svc" "$K8S_NAMESPACE"
    printf 'DNS:%s.%s.svc.%s\n' "$svc" "$K8S_NAMESPACE" "$CLUSTER_DOMAIN"
    printf 'DNS:localhost\n'
    printf 'IP:127.0.0.1\n'
    while IFS= read -r item; do
      if [[ "$item" =~ $re_ip ]]; then printf 'IP:%s\n' "$item"; else printf 'DNS:%s\n' "$item"; fi
    done < <(
      csv_split "$extra"
      printf '%s\n' "$public_host"
    )
  } | awk 'NF && !seen[$0]++'
}

# _certs_fingerprint NAME - what the certificate SHOULD contain. Stored next to
# the certificate so configuration drift (new SAN, new subject, new key type)
# is detected. The lifetime is left out on purpose: changing CERT_LEAF_DAYS
# applies at the next renewal instead of forcing one.
_certs_fingerprint() {
  local name=$1 profile
  profile=$(_certs_profile "$name")
  printf 'subject=%s\n' "$(certs_subject_dn "$name")"
  printf 'profile=%s\n' "${profile%|*}"
  _certs_sans "$name" | sed 's/^/san=/'
}

_certs_write_cnf() {
  local name=$1 cnf=$2 profile ku eku sans dns=0 ip=0 san
  profile=$(_certs_profile "$name")
  IFS='|' read -r _ ku eku _ <<<"$profile"
  sans=$(_certs_sans "$name")
  {
    printf '[req]\ndistinguished_name = dn\n[dn]\n'
    printf '[v3_leaf]\n'
    printf 'basicConstraints = critical, CA:FALSE\n'
    printf 'keyUsage = critical, %s\n' "$ku"
    if [[ "$eku" != "-" ]]; then printf 'extendedKeyUsage = %s\n' "$eku"; fi
    printf 'subjectKeyIdentifier = hash\n'
    printf 'authorityKeyIdentifier = keyid,issuer\n'
    if [[ -n "$sans" ]]; then
      printf 'subjectAltName = @alt_names\n[alt_names]\n'
      while IFS= read -r san; do
        case "$san" in
          DNS:*)
            dns=$((dns + 1))
            printf 'DNS.%d = %s\n' "$dns" "${san#DNS:}"
            ;;
          IP:*)
            ip=$((ip + 1))
            printf 'IP.%d = %s\n' "$ip" "${san#IP:}"
            ;;
        esac
      done <<<"$sans"
    fi
  } >"$cnf"
}

certs_ca_exists() {
  [[ -s "$(certs_path ca ca.crt)" && -s "$(certs_path ca ca.key)" ]]
}

# certs_create_ca - self-signed root, pathlen 0 (it may only sign leaves).
certs_create_ca() {
  local dir="${CERT_DIR}/ca" tmp
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] create CA in %s\n' "$dir"
    return 0
  fi
  mkdir -p "$dir"
  chmod 700 "$dir"
  tmp=$(platform_tmpdir)
  cat >"${tmp}/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
[dn]
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  _certs_genkey "$CERT_KEY_ALG" "${tmp}/ca.key" ca
  openssl req -x509 -new -key "${tmp}/ca.key" -sha384 -days "$CERT_CA_DAYS" \
    -subj "$(_certs_openssl_subject "${PROJECT_NAME} Root CA")" \
    -config "${tmp}/ca.cnf" -extensions v3_ca -out "${tmp}/ca.crt" ||
    die "certs: CA creation failed"
  mv "${tmp}/ca.key" "${dir}/ca.key"
  mv "${tmp}/ca.crt" "${dir}/ca.crt"
  chmod 644 "${dir}/ca.crt"
  rm -rf "$tmp"
  log_info "certs: created CA $(certs_subject_dn "${PROJECT_NAME} Root CA") (${CERT_CA_DAYS} days)"
}

# _certs_issue_reason NAME FORCE - print why NAME must be issued, or nothing.
_certs_issue_reason() {
  local name=$1 force=$2 crt key info
  crt=$(certs_path "$name" tls.crt)
  key=$(certs_path "$name" tls.key)
  info=$(certs_path "$name" cert.info)
  if [[ "$force" == "1" ]]; then
    printf 'forced'
  elif [[ ! -s "$crt" || ! -s "$key" ]]; then
    printf 'missing'
  elif ! openssl verify -CAfile "$(certs_path ca ca.crt)" "$crt" >/dev/null 2>&1; then
    printf 'not signed by the current CA'
  elif [[ ! -f "$info" || "$(cat "$info")" != "$(_certs_fingerprint "$name")" ]]; then
    printf 'subject / SAN / profile changed'
  elif ! openssl x509 -in "$crt" -noout -checkend "$((CERT_RENEW_BEFORE_DAYS * 86400))" >/dev/null 2>&1; then
    if [[ "$name" == "saml-sp" ]]; then
      # Rotating the SAML signing certificate needs a matching change in Keycloak.
      log_warn "certs: saml-sp expires within ${CERT_RENEW_BEFORE_DAYS} days; rotate it deliberately with: certs --only saml-sp --force"
    else
      printf 'expires within %s days' "$CERT_RENEW_BEFORE_DAYS"
    fi
  fi
}

# certs_create_leaf NAME - new key + certificate, moved into place atomically.
certs_create_leaf() {
  local name=$1 dir="${CERT_DIR}/$1" tmp profile alg days
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] issue certificate %s in %s\n' "$name" "$dir"
    return 0
  fi
  profile=$(_certs_profile "$name")
  IFS='|' read -r alg _ _ days <<<"$profile"
  tmp=$(platform_tmpdir)
  _certs_write_cnf "$name" "${tmp}/leaf.cnf"
  _certs_genkey "$alg" "${tmp}/tls.key"
  openssl req -new -key "${tmp}/tls.key" -subj "$(_certs_openssl_subject "$name")" \
    -config "${tmp}/leaf.cnf" -out "${tmp}/leaf.csr" ||
    die "certs: CSR creation failed for ${name}"
  openssl x509 -req -in "${tmp}/leaf.csr" \
    -CA "$(certs_path ca ca.crt)" -CAkey "$(certs_path ca ca.key)" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$days" -sha256 \
    -extfile "${tmp}/leaf.cnf" -extensions v3_leaf -out "${tmp}/tls.crt" 2>/dev/null ||
    die "certs: signing failed for ${name}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  mv "${tmp}/tls.key" "${dir}/tls.key"
  mv "${tmp}/tls.crt" "${dir}/tls.crt"
  chmod 644 "${dir}/tls.crt"
  cp "$(certs_path ca ca.crt)" "${dir}/ca.crt"
  _certs_fingerprint "$name" >"${dir}/cert.info"
  rm -f "${dir}/keystore.p12" "${dir}/truststore.p12" "${dir}/keystore.password"
  rm -rf "$tmp"
  log_info "certs: issued ${name} ($(certs_subject_dn "$name"), ${days} days)"
}

# certs_write_pkcs12 NAME - optional keystore/truststore for JVM consumers
# that cannot read PEM. The random password is written next to the stores.
certs_write_pkcs12() {
  local name=$1 dir="${CERT_DIR}/$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] write PKCS#12 stores for %s\n' "$name"
    return 0
  fi
  if [[ -s "${dir}/keystore.p12" && "${dir}/keystore.p12" -nt "${dir}/tls.crt" ]]; then return 0; fi
  (
    umask 077
    openssl rand -hex 24 >"${dir}/keystore.password"
    openssl pkcs12 -export -name "$name" -inkey "${dir}/tls.key" -in "${dir}/tls.crt" \
      -certfile "${dir}/ca.crt" -passout "file:${dir}/keystore.password" -out "${dir}/keystore.p12"
  ) || die "certs: PKCS#12 export failed for ${name}"
  if have_cmd keytool; then
    rm -f "${dir}/truststore.p12"
    keytool -importcert -noprompt -alias platform-ca -file "${dir}/ca.crt" \
      -keystore "${dir}/truststore.p12" -storetype PKCS12 \
      -storepass:file "${dir}/keystore.password" >/dev/null 2>&1 ||
      die "certs: truststore creation failed for ${name}"
    chmod 600 "${dir}/truststore.p12"
  else
    log_warn "certs: keytool not found, skipping truststore.p12 for ${name}"
  fi
  log_info "certs: wrote PKCS#12 stores for ${name}"
}

_certs_pubkey_hash() { openssl sha256 | awk '{print $NF}'; }

# certs_verify_leaf NAME - chain, key/cert match, expiry and intended purpose.
certs_verify_leaf() {
  local name=$1 crt key ca purpose
  crt=$(certs_path "$name" tls.crt)
  key=$(certs_path "$name" tls.key)
  ca=$(certs_path ca ca.crt)
  if [[ ! -s "$crt" || ! -s "$key" ]]; then
    log_error "certs: ${name}: certificate or key missing"
    return 1
  fi
  if ! openssl verify -CAfile "$ca" "$crt" >/dev/null 2>&1; then
    log_error "certs: ${name}: does not chain to ${ca}"
    return 1
  fi
  if [[ "$(openssl x509 -in "$crt" -noout -pubkey | _certs_pubkey_hash)" != \
    "$(openssl pkey -in "$key" -pubout 2>/dev/null | _certs_pubkey_hash)" ]]; then
    log_error "certs: ${name}: private key does not match certificate"
    return 1
  fi
  if ! openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
    log_error "certs: ${name}: certificate has expired"
    return 1
  fi
  for purpose in $(_certs_purposes "$name"); do
    if ! openssl verify -CAfile "$ca" -purpose "$purpose" "$crt" >/dev/null 2>&1; then
      log_error "certs: ${name}: not valid for purpose ${purpose}"
      return 1
    fi
  done
  if [[ "$(stat -c '%a' "$key" 2>/dev/null || stat -f '%Lp' "$key")" != "600" ]]; then
    log_error "certs: ${name}: ${key} must have mode 600"
    return 1
  fi
  return 0
}

_certs_purposes() {
  case "$1" in
    keycloak) printf 'sslserver' ;;
    spring-app) printf 'sslserver sslclient' ;;
    test-client) printf 'sslclient' ;;
    *) printf '' ;;
  esac
}

# certs_verify [NAMES...] - verify all (or the given) leaves; non-zero on failure.
certs_verify() {
  local name failed=0
  local names=("$@")
  if ((${#names[@]} == 0)); then names=("${CERT_LEAVES[@]}"); fi
  if ! certs_ca_exists; then
    log_error "certs: no CA in ${CERT_DIR}/ca (run: platform.sh certs)"
    return 1
  fi
  for name in "${names[@]}"; do
    if certs_verify_leaf "$name"; then
      log_info "certs: ${name}: OK, $(openssl x509 -in "$(certs_path "$name" tls.crt)" -noout -enddate | sed 's/notAfter=/expires /')"
    else
      failed=1
    fi
  done
  return "$failed"
}

# certs_require COMPONENT_CERT_NAMES... - used by build/secrets/deploy.
certs_require() {
  local name
  certs_ca_exists || die "No CA found in ${CERT_DIR}. Run: platform.sh certs"
  for name in "$@"; do
    [[ -s "$(certs_path "$name" tls.crt)" && -s "$(certs_path "$name" tls.key)" ]] ||
      die "Certificate '${name}' not found in ${CERT_DIR}. Run: platform.sh certs"
  done
}

certs_main() {
  local force=0 force_ca=0 pkcs12=0 verify_only=0 only="" name reason selected=() list
  while (($# > 0)); do
    case "$1" in
      --only)
        [[ $# -ge 2 ]] || die "certs: --only needs a value" 2
        only=$2
        shift
        ;;
      --force) force=1 ;;
      --force-ca) force_ca=1 ;;
      --pkcs12) pkcs12=1 ;;
      --verify) verify_only=1 ;;
      -h | --help)
        certs_usage
        return 0
        ;;
      *) die "certs: unknown option '$1' (see: platform.sh certs --help)" 2 ;;
    esac
    shift
  done

  if [[ -n "$only" ]]; then
    list=$(csv_split "$only")
    while IFS= read -r name; do
      contains "$name" "${CERT_LEAVES[@]}" || die "certs: unknown certificate '${name}' (allowed: ${CERT_LEAVES[*]})" 2
      selected+=("$name")
    done <<<"$list"
  else
    selected=("${CERT_LEAVES[@]}")
  fi

  require_cmd openssl "Install OpenSSL 1.1.1+ or LibreSSL 3+."

  if [[ "$verify_only" == "1" ]]; then
    certs_verify "${selected[@]}"
    return $?
  fi

  log_step "Certificates in ${CERT_DIR}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    mkdir -p "$CERT_DIR"
    chmod 700 "$CERT_DIR"
  fi

  if [[ "$force_ca" == "1" ]] || ! certs_ca_exists; then
    if [[ "$force_ca" == "1" ]] && certs_ca_exists; then
      log_warn "certs: replacing the CA; every existing certificate becomes invalid"
    fi
    certs_create_ca
  elif ! openssl x509 -in "$(certs_path ca ca.crt)" -noout -checkend "$((CERT_RENEW_BEFORE_DAYS * 86400))" >/dev/null 2>&1; then
    log_warn "certs: the CA expires within ${CERT_RENEW_BEFORE_DAYS} days; plan a rotation (certs --force-ca)"
  fi

  for name in "${selected[@]}"; do
    if [[ "${DRY_RUN}" == "1" ]] && ! certs_ca_exists; then
      reason="missing"
    else
      reason=$(_certs_issue_reason "$name" "$force")
    fi
    if [[ -n "$reason" ]]; then
      log_info "certs: ${name}: ${reason} -> issuing"
      certs_create_leaf "$name"
    else
      log_debug "certs: ${name}: up to date"
    fi
    if [[ "$pkcs12" == "1" ]]; then certs_write_pkcs12 "$name"; fi
  done

  if [[ "${DRY_RUN}" != "1" ]]; then
    certs_verify "${selected[@]}" || die "certs: verification failed"
  fi
}
