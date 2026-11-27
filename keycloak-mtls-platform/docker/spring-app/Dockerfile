# =============================================================================
# Java 25 Spring Boot app (OIDC + SAML + mTLS API).
#
# Build context (staged by `platform.sh build`, see scripts/lib/images.sh):
#   apps/         Maven reactor (wrapper, spring-app, test-client)
#   certs/trust/  ca.crt                 (CERT_MODE=trust|baked)
#   certs/tls/    tls.crt tls.key ca.crt (CERT_MODE=baked only - demos)
#   certs/saml/   tls.crt tls.key        (CERT_MODE=baked only - demos)
# Plain Dockerfile syntax on purpose (no BuildKit-only features) so the same
# file also builds with ACR Tasks. Docs: docs/04-images.md
# =============================================================================
ARG JAVA_BUILD_IMAGE=eclipse-temurin:25-jdk
ARG JAVA_RUNTIME_IMAGE=eclipse-temurin:25-jre

# ---- build: package with the Maven Wrapper (tests run in `platform.sh verify`)
FROM ${JAVA_BUILD_IMAGE} AS build
WORKDIR /workspace
COPY apps/ ./
RUN chmod +x mvnw \
    && ./mvnw --batch-mode --no-transfer-progress --projects spring-app -DskipTests package

# ---- extract: split the fat jar into layers that change at different rates ---
FROM ${JAVA_RUNTIME_IMAGE} AS extract
WORKDIR /builder
COPY --from=build /workspace/spring-app/target/spring-app.jar application.jar
RUN java -Djarmode=tools -jar application.jar extract --layers --destination extracted

# ---- runtime ------------------------------------------------------------------
FROM ${JAVA_RUNTIME_IMAGE}

# Unprivileged user; works on Debian/Ubuntu and on Alpine based runtime images.
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
COPY --chown=10001:10001 certs/saml/ /etc/platform/saml/
# Load the platform CA into the JVM trust store (public data, safe to ship).
RUN if [ -f /etc/platform/trust/ca.crt ]; then \
      keytool -importcert -noprompt -cacerts -storepass changeit \
        -alias platform-ca -file /etc/platform/trust/ca.crt; \
    fi

COPY --from=extract /builder/extracted/dependencies/ ./
COPY --from=extract /builder/extracted/spring-boot-loader/ ./
COPY --from=extract /builder/extracted/snapshot-dependencies/ ./
COPY --from=extract /builder/extracted/application/ ./

USER 10001:10001
EXPOSE 8443 9443
# Extra JVM flags: set the JDK_JAVA_OPTIONS environment variable.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+ExitOnOutOfMemoryError", "-XX:+UseCompactObjectHeaders", "-Djava.io.tmpdir=/tmp", "-jar", "application.jar"]
