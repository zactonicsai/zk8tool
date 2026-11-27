package com.example.platform.client;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import java.nio.file.Path;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import org.junit.jupiter.api.Test;

class ConfigTest {

    @Test
    void onlyTheKeycloakUrlIsRequired() {
        Config config = Config.fromEnvironment(Map.of("KEYCLOAK_URL", "https://keycloak.iam.svc:8443/"));

        assertEquals(URI.create("https://keycloak.iam.svc:8443"), config.keycloakUrl());
        assertEquals("platform", config.realm());
        assertEquals("https://keycloak.iam.svc:8443/realms/platform", config.realmUrl());
        assertEquals("https://keycloak.iam.svc:8443/realms/platform", config.expectedIssuer());
        assertEquals("test-client", config.clientId());
        assertEquals("spring-app", config.expectedAudience());
        assertEquals("api-read", config.expectedRole());
        assertEquals("keycloak", config.appRegistration());
        assertEquals(Path.of("/etc/platform/tls/tls.crt"), config.certificateFile());
        assertEquals(Path.of("/etc/platform/tls/tls.key"), config.keyFile());
        assertEquals(Path.of("/etc/platform/tls/ca.crt"), config.caFile());
        assertEquals(Duration.ofDays(7), config.minValidity());
        assertEquals(Set.of("TLSv1.3"), config.tlsProtocols());
        assertEquals(Duration.ofSeconds(10), config.timeout());
        assertEquals(Duration.ofSeconds(120), config.waitTimeout());
        assertEquals(Config.ALL_GROUPS, config.groups());
        assertFalse(config.appUrl().isPresent());
        assertFalse(config.keycloakMgmtUrl().isPresent());
        assertFalse(config.junitReport().isPresent());
    }

    @Test
    void publicIssuerMayDifferFromTheUrlTheClientConnectsTo() {
        Map<String, String> env = new HashMap<>();
        env.put("KEYCLOAK_URL", "https://iam-keycloak.iam.svc.cluster.local:8443");
        env.put("KEYCLOAK_ISSUER", "https://sso.example.com/realms/corp/");
        env.put("KEYCLOAK_REALM", "corp");

        Config config = Config.fromEnvironment(env);

        assertEquals("https://iam-keycloak.iam.svc.cluster.local:8443/realms/corp", config.realmUrl());
        assertEquals("https://sso.example.com/realms/corp", config.expectedIssuer());
    }

    @Test
    void readsEveryOptionalSetting() {
        Map<String, String> env = new HashMap<>();
        env.put("KEYCLOAK_URL", "https://kc:8443");
        env.put("KEYCLOAK_MGMT_URL", "https://kc:9000");
        env.put("APP_URL", "https://app:8443");
        env.put("APP_MGMT_URL", "https://app:9443");
        env.put("CHECKS", "certs, keycloak");
        env.put("EXPECTED_TLS_PROTOCOLS", "TLSv1.3,TLSv1.2");
        env.put("MIN_CERT_VALID_DAYS", "30");
        env.put("WAIT_TIMEOUT_SECONDS", "0");
        env.put("REPORT_JUNIT_FILE", "/tmp/report.xml");

        Config config = Config.fromEnvironment(env);

        assertEquals(URI.create("https://kc:9000"), config.keycloakMgmtUrl().orElseThrow());
        assertEquals(URI.create("https://app:8443"), config.appUrl().orElseThrow());
        assertEquals(URI.create("https://app:9443"), config.appMgmtUrl().orElseThrow());
        assertEquals(Set.of("certs", "keycloak"), config.groups());
        assertEquals(Set.of("TLSv1.3", "TLSv1.2"), config.tlsProtocols());
        assertEquals(Duration.ofDays(30), config.minValidity());
        assertEquals(Duration.ZERO, config.waitTimeout());
        assertEquals(Path.of("/tmp/report.xml"), config.junitReport().orElseThrow());
    }

    @Test
    void blankValuesCountAsUnset() {
        Map<String, String> env = new HashMap<>();
        env.put("KEYCLOAK_URL", "https://kc:8443");
        env.put("APP_URL", "   ");
        env.put("KEYCLOAK_REALM", "");

        Config config = Config.fromEnvironment(env);

        assertFalse(config.appUrl().isPresent());
        assertEquals("platform", config.realm());
    }

    @Test
    void reportsTheOffendingVariable() {
        assertInvalid(Map.of(), "KEYCLOAK_URL");
        assertInvalid(Map.of("KEYCLOAK_URL", "http://kc:8080"), "KEYCLOAK_URL");
        assertInvalid(Map.of("KEYCLOAK_URL", "https://kc", "APP_URL", "ftp://app"), "APP_URL");
        assertInvalid(Map.of("KEYCLOAK_URL", "https://kc", "CHECKS", "certs,bogus"), "CHECKS");
        assertInvalid(Map.of("KEYCLOAK_URL", "https://kc", "MIN_CERT_VALID_DAYS", "0"), "MIN_CERT_VALID_DAYS");
        assertInvalid(Map.of("KEYCLOAK_URL", "https://kc", "HTTP_TIMEOUT_SECONDS", "abc"), "HTTP_TIMEOUT_SECONDS");
        assertInvalid(Map.of("KEYCLOAK_URL", "https://kc", "WAIT_TIMEOUT_SECONDS", "-1"), "WAIT_TIMEOUT_SECONDS");
    }

    private static void assertInvalid(Map<String, String> env, String variable) {
        Config.InvalidConfigException error = assertThrows(Config.InvalidConfigException.class,
                () -> Config.fromEnvironment(env));
        assertTrue(error.getMessage().contains(variable));
    }
}
