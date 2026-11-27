# =============================================================================
# Java 25 connectivity / certificate test client (runs as the Helm test pod).
#
# Build context (staged by `platform.sh build`, see scripts/lib/images.sh):
#   apps/         Maven reactor (wrapper, spring-app, test-client)
#   certs/trust/  ca.crt                 (CERT_MODE=trust|baked)
#   certs/tls/    tls.crt tls.key ca.crt (CERT_MODE=baked only - demos)
# The client has no third-party dependencies: the image is a JRE plus one jar.
# Docs: docs/04-images.md
# =============================================================================
ARG JAVA_BUILD_IMAGE=eclipse-temurin:25-jdk
ARG JAVA_RUNTIME_IMAGE=eclipse-temurin:25-jre

# ---- build (tests run in `platform.sh verify`) --------------------------------
FROM ${JAVA_BUILD_IMAGE} AS build
WORKDIR /workspace
COPY apps/ ./
RUN chmod +x mvnw \
    && ./mvnw --batch-mode --no-transfer-progress --projects test-client -DskipTests package

# ---- runtime ------------------------------------------------------------------
FROM ${JAVA_RUNTIME_IMAGE}

RUN if command -v useradd >/dev/null 2>&1; then \
      groupadd --system --gid 10001 app \
      && useradd --system --uid 10001 --gid 10001 --home-dir /application --no-create-home --shell /usr/sbin/nologin app; \
    else \
      addgroup -S -g 10001 app \
      && adduser -S -D -H -u 10001 -G app -h /application -s /sbin/nologin app; \
    fi

WORKDIR /application

COPY --chown=10001:10001 certs/trust/ /etc/platform/trust/
COPY --chown=10001:10001 certs/tls/ /etc/platform/tls/
COPY --from=build /workspace/test-client/target/test-client.jar test-client.jar

USER 10001:10001
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+ExitOnOutOfMemoryError", "-XX:+UseCompactObjectHeaders", "-jar", "test-client.jar"]
