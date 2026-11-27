package com.example.platform.client;

import java.net.URI;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.function.Function;

/**
 * Settings of one test run, read from environment variables so the same image
 * works as a Helm test pod, a Kubernetes Job or a local {@code java -jar}.
 *
 * @param keycloakUrl      base URL the client connects to, e.g. {@code https://iam-keycloak.iam.svc.cluster.local:8443}
 * @param realm            Keycloak realm
 * @param expectedIssuer   issuer expected in discovery and tokens (the public Keycloak URL + realm)
 * @param keycloakMgmtUrl  management interface (health), optional
 * @param appUrl           base URL of the Spring app, optional; app checks are skipped when absent
 * @param appMgmtUrl       management port of the app (actuator health), optional
 * @param appRegistration  registration id used by the app for both OIDC and SAML
 * @param clientId         OIDC client used for the client-credentials grant
 * @param expectedAudience audience the access token must carry
 * @param expectedRole     realm role the access token must carry
 * @param certificateFile  PEM client certificate (chain)
 * @param keyFile          PEM PKCS#8 private key
 * @param caFile           PEM CA bundle: the only trust anchors used
 * @param minValidity      shortest acceptable remaining lifetime of any certificate
 * @param tlsProtocols     acceptable negotiated TLS versions
 * @param timeout          per-request timeout
 * @param waitTimeout      how long to wait for the targets to come up before testing
 * @param groups           which check groups to run: certs, keycloak, app
 * @param junitReport      where to write a JUnit XML report, optional
 */
record Config(
        URI keycloakUrl,
        String realm,
        String expectedIssuer,
        Optional<URI> keycloakMgmtUrl,
        Optional<URI> appUrl,
        Optional<URI> appMgmtUrl,
        String appRegistration,
        String clientId,
        String expectedAudience,
        String expectedRole,
        Path certificateFile,
        Path keyFile,
        Path caFile,
        Duration minValidity,
        Set<String> tlsProtocols,
        Duration timeout,
        Duration waitTimeout,
        Set<String> groups,
        Optional<Path> junitReport) {

    static final Set<String> ALL_GROUPS = Set.of("certs", "keycloak", "app");

    /** Thrown for a missing or malformed setting; the message names the variable. */
    static final class InvalidConfigException extends RuntimeException {

        private static final long serialVersionUID = 1L;

        InvalidConfigException(String message) {
            super(message);
        }
    }

    static Config fromEnvironment(Map<String, String> env) {
        Function<String, Optional<String>> get = name -> Optional.ofNullable(env.get(name))
                .map(String::strip).filter(value -> !value.isEmpty());

        URI keycloakUrl = get.apply("KEYCLOAK_URL").map(value -> httpsUri("KEYCLOAK_URL", value))
                .orElseThrow(() -> new InvalidConfigException("KEYCLOAK_URL is required"));
        String realm = get.apply("KEYCLOAK_REALM").orElse("platform");
        String issuer = get.apply("KEYCLOAK_ISSUER").map(Config::stripTrailingSlash)
                .orElse(stripTrailingSlash(keycloakUrl.toString()) + "/realms/" + realm);

        Set<String> groups = csv(get.apply("CHECKS").orElse("certs,keycloak,app"));
        if (!ALL_GROUPS.containsAll(groups)) {
            throw new InvalidConfigException("CHECKS may only contain " + ALL_GROUPS + " but was " + groups);
        }

        return new Config(
                keycloakUrl,
                realm,
                issuer,
                get.apply("KEYCLOAK_MGMT_URL").map(value -> httpsUri("KEYCLOAK_MGMT_URL", value)),
                get.apply("APP_URL").map(value -> httpsUri("APP_URL", value)),
                get.apply("APP_MGMT_URL").map(value -> httpsUri("APP_MGMT_URL", value)),
                get.apply("APP_REGISTRATION_ID").orElse("keycloak"),
                get.apply("OIDC_CLIENT_ID").orElse("test-client"),
                get.apply("EXPECTED_AUDIENCE").orElse("spring-app"),
                get.apply("EXPECTED_ROLE").orElse("api-read"),
                Path.of(get.apply("TLS_CERT_FILE").orElse("/etc/platform/tls/tls.crt")),
                Path.of(get.apply("TLS_KEY_FILE").orElse("/etc/platform/tls/tls.key")),
                Path.of(get.apply("TLS_CA_FILE").orElse("/etc/platform/tls/ca.crt")),
                Duration.ofDays(positiveLong("MIN_CERT_VALID_DAYS", get.apply("MIN_CERT_VALID_DAYS").orElse("7"))),
                csv(get.apply("EXPECTED_TLS_PROTOCOLS").orElse("TLSv1.3")),
                Duration.ofSeconds(positiveLong("HTTP_TIMEOUT_SECONDS", get.apply("HTTP_TIMEOUT_SECONDS").orElse("10"))),
                Duration.ofSeconds(nonNegativeLong("WAIT_TIMEOUT_SECONDS", get.apply("WAIT_TIMEOUT_SECONDS").orElse("120"))),
                groups,
                get.apply("REPORT_JUNIT_FILE").map(Path::of));
    }

    /** {@code <keycloakUrl>/realms/<realm>} - the realm base on the URL the client actually connects to. */
    String realmUrl() {
        return stripTrailingSlash(keycloakUrl.toString()) + "/realms/" + realm;
    }

    private static URI httpsUri(String name, String value) {
        URI uri;
        try {
            uri = URI.create(stripTrailingSlash(value));
        } catch (IllegalArgumentException e) {
            throw new InvalidConfigException(name + " is not a valid URI: " + value);
        }
        if (!"https".equals(uri.getScheme()) || uri.getHost() == null) {
            throw new InvalidConfigException(name + " must be an https:// URL but was: " + value);
        }
        return uri;
    }

    private static String stripTrailingSlash(String value) {
        return value.endsWith("/") ? value.substring(0, value.length() - 1) : value;
    }

    private static Set<String> csv(String value) {
        Set<String> items = new LinkedHashSet<>();
        Arrays.stream(value.split(",")).map(String::strip).filter(item -> !item.isEmpty()).forEach(items::add);
        return Set.copyOf(items);
    }

    private static long positiveLong(String name, String value) {
        long number = nonNegativeLong(name, value);
        if (number == 0) {
            throw new InvalidConfigException(name + " must be greater than zero");
        }
        return number;
    }

    private static long nonNegativeLong(String name, String value) {
        try {
            long number = Long.parseLong(value);
            if (number < 0) {
                throw new NumberFormatException();
            }
            return number;
        } catch (NumberFormatException e) {
            throw new InvalidConfigException(name + " must be a non-negative integer but was: " + value);
        }
    }
}
