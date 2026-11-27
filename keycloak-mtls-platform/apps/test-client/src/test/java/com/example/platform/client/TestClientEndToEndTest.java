package com.example.platform.client;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * Runs the whole client against {@link FakePlatform} over real mutual TLS:
 * first the happy path, then one misconfiguration at a time to prove that the
 * matching check (and only a failing run) reports it.
 */
class TestClientEndToEndTest {

    private FakePlatform platform;
    private String output;

    @BeforeEach
    void startPlatform() throws Exception {
        platform = new FakePlatform();
    }

    @AfterEach
    void stopPlatform() {
        platform.close();
    }

    private int run(Map<String, String> environment) {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int exitCode = TestClient.run(environment, new PrintStream(buffer, true, StandardCharsets.UTF_8));
        output = buffer.toString(StandardCharsets.UTF_8);
        return exitCode;
    }

    private void assertFailed(String checkId) {
        assertTrue(output.contains("[FAIL] " + checkId), "expected " + checkId + " to fail:\n" + output);
    }

    private void assertPassed(String checkId) {
        assertTrue(output.contains("[PASS] " + checkId), "expected " + checkId + " to pass:\n" + output);
    }

    @Test
    void everyCheckPassesAgainstACorrectlyConfiguredPlatform() {
        int exitCode = run(platform.environment());

        assertEquals(TestClient.EXIT_OK, exitCode, output);
        assertFalse(output.contains("[FAIL]"), output);
        assertFalse(output.contains("[SKIP]"), output);
        assertTrue(output.contains("Summary: 25 passed, 0 failed, 0 skipped"), output);
        assertTrue(output.contains("TLSv1.3"), output);
    }

    @Test
    void writesAJunitReport() throws Exception {
        Path report = Files.createTempFile("platform-report", ".xml");
        try {
            Map<String, String> environment = platform.environment();
            environment.put("REPORT_JUNIT_FILE", report.toString());

            assertEquals(TestClient.EXIT_OK, run(environment), output);
            String xml = Files.readString(report);
            assertTrue(xml.contains("tests=\"25\" failures=\"0\" skipped=\"0\""), xml);
        } finally {
            Files.deleteIfExists(report);
        }
    }

    @Test
    void appChecksAreSkippedWhenNoAppUrlIsConfigured() {
        Map<String, String> environment = platform.environment();
        environment.remove("APP_URL");
        environment.remove("APP_MGMT_URL");
        environment.remove("KEYCLOAK_MGMT_URL");

        assertEquals(TestClient.EXIT_OK, run(environment), output);
        assertTrue(output.contains("[SKIP] KC-02"), output);
        assertTrue(output.contains("[SKIP] APP "), output);
    }

    @Test
    void onlyTheSelectedGroupsRun() {
        Map<String, String> environment = platform.environment();
        environment.put("CHECKS", "certs");

        assertEquals(TestClient.EXIT_OK, run(environment), output);
        assertTrue(output.contains("Summary: 5 passed, 0 failed, 0 skipped"), output);
    }

    @Test
    void failsWhenTheTokenEndpointDoesNotDemandAClientCertificate() {
        platform.tokenEndpointRequiresCertificate = false;

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(platform.environment()), output);
        assertFailed("KC-06");
        assertPassed("KC-05");
    }

    @Test
    void failsWhenTheApiDoesNotEnforceMutualTls() {
        platform.apiRequiresCertificate = false;

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(platform.environment()), output);
        assertFailed("APP-05");
        assertPassed("APP-03");
    }

    @Test
    void failsWhenTheTokenHasTheWrongAudience() {
        platform.audience = "some-other-api";

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(platform.environment()), output);
        assertFailed("KC-07");
    }

    @Test
    void failsWhenTheTokenIsNotCertificateBound() {
        platform.bindTokensToCertificate = false;

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(platform.environment()), output);
        assertFailed("KC-08");
    }

    @Test
    void failsWhenTheOidcRedirectLacksPkce() {
        platform.pkce = false;

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(platform.environment()), output);
        assertFailed("APP-07");
    }

    @Test
    void failsWhenTheIssuerDiffersFromTheExpectedOne() {
        Map<String, String> environment = platform.environment();
        environment.put("KEYCLOAK_ISSUER", "https://sso.example.com/realms/platform");

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(environment), output);
        assertFailed("KC-03");
    }

    @Test
    void failsWhenTheServerCertificateIsNotIssuedByTheTrustedCa() {
        Map<String, String> environment = platform.environment();
        environment.put("TLS_CA_FILE", Fixtures.cert("untrusted-ca.crt").toString());

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(environment), output);
        assertFailed("KC-01");
        // The client certificate does not chain to that CA either.
        assertFailed("CERT-02");
    }

    @Test
    void failsWhenAStricterTlsVersionIsDemandedThanNegotiated() {
        Map<String, String> environment = platform.environment();
        environment.put("EXPECTED_TLS_PROTOCOLS", "TLSv9.9");

        assertEquals(TestClient.EXIT_CHECKS_FAILED, run(environment), output);
        assertFailed("KC-01");
        assertFailed("APP-01");
    }

    @Test
    void waitOnlyReturnsAsSoonAsKeycloakAnswers() {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int exitCode = TestClient.execute(new String[] {"--wait-only"}, platform.environment(),
                new PrintStream(buffer, true, StandardCharsets.UTF_8));
        output = buffer.toString(StandardCharsets.UTF_8);

        assertEquals(TestClient.EXIT_OK, exitCode, output);
        assertTrue(output.contains("Keycloak is reachable over mutual TLS"), output);
        assertFalse(output.contains("[PASS]"), output);
    }

    @Test
    void waitOnlyGivesUpAfterTheTimeout() {
        Map<String, String> environment = platform.environment();
        // A realm the fake does not serve: the probe keeps getting 404.
        environment.put("KEYCLOAK_REALM", "missing");
        environment.put("WAIT_TIMEOUT_SECONDS", "0");
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();

        int exitCode = TestClient.execute(new String[] {"--wait-only"}, environment,
                new PrintStream(buffer, true, StandardCharsets.UTF_8));
        output = buffer.toString(StandardCharsets.UTF_8);

        assertEquals(TestClient.EXIT_CHECKS_FAILED, exitCode, output);
        assertTrue(output.contains("not ready"), output);
    }

    @Test
    void unknownArgumentsPrintUsage() {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();

        int exitCode = TestClient.execute(new String[] {"--bogus"}, platform.environment(),
                new PrintStream(buffer, true, StandardCharsets.UTF_8));

        assertEquals(TestClient.EXIT_CONFIG_ERROR, exitCode);
        assertTrue(buffer.toString(StandardCharsets.UTF_8).contains("--wait-only"));
    }

    @Test
    void configurationErrorsExitWithCodeTwo() {
        assertEquals(TestClient.EXIT_CONFIG_ERROR, run(Map.of()), output);
        assertTrue(output.contains("KEYCLOAK_URL"), output);

        Map<String, String> environment = platform.environment();
        environment.put("TLS_KEY_FILE", "/nonexistent/tls.key");
        assertEquals(TestClient.EXIT_CONFIG_ERROR, run(environment), output);
        assertTrue(output.contains("Cannot load certificate material"), output);
    }
}
