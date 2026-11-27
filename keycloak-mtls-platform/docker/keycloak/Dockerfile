# =============================================================================
# Keycloak, pre-built ("optimized") for one database vendor, with the realm
# import file and the platform CA loaded into the image.
#
# Build context (staged by `platform.sh build`, see scripts/lib/images.sh):
#   realm/        realm import file(s)
#   certs/trust/  ca.crt             (CERT_MODE=trust|baked)
#   certs/tls/    tls.crt tls.key    (CERT_MODE=baked only - demos)
# Docs: docs/04-images.md
# =============================================================================
ARG KEYCLOAK_BASE_IMAGE=quay.io/keycloak/keycloak
ARG KEYCLOAK_VERSION=26.8.2

# ---- builder: augment the server once, at image build time -------------------
FROM ${KEYCLOAK_BASE_IMAGE}:${KEYCLOAK_VERSION} AS builder

# BUILD options: fixed when `kc.sh build` runs. Changing one means rebuilding
# the image; they cannot be changed with environment variables at runtime.
ARG KC_DB=postgres
ARG KC_HTTPS_CLIENT_AUTH=request
ENV KC_DB=${KC_DB} \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_HTTPS_CLIENT_AUTH=${KC_HTTPS_CLIENT_AUTH} \
    KC_HTTPS_MANAGEMENT_CLIENT_AUTH=none

WORKDIR /opt/keycloak
COPY --chown=keycloak:root realm/ data/import/
# PEM files in conf/truststores are trusted for outgoing TLS and for
# validating client certificates (mTLS).
COPY --chown=keycloak:root certs/trust/ conf/truststores/
RUN rm -f conf/truststores/.placeholder \
    && bin/kc.sh build

# ---- runtime ------------------------------------------------------------------
FROM ${KEYCLOAK_BASE_IMAGE}:${KEYCLOAK_VERSION}

ARG KC_DB=postgres
ARG KC_HTTPS_CLIENT_AUTH=request
ENV KC_DB=${KC_DB} \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_HTTPS_CLIENT_AUTH=${KC_HTTPS_CLIENT_AUTH} \
    KC_HTTPS_MANAGEMENT_CLIENT_AUTH=none

COPY --from=builder /opt/keycloak/ /opt/keycloak/
# Empty unless CERT_MODE=baked. A Secret mounted at this path replaces it.
COPY --chown=keycloak:root certs/tls/ /etc/platform/tls/

USER 1000
EXPOSE 8443 9000
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm"]
