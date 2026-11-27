package com.example.platform.client;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

class CertificateChecksTest {

    private static List<CheckRunner.Result> run(TlsMaterial tls, Map<String, String> overrides) {
        Map<String, String> env = new HashMap<>(Map.of("KEYCLOAK_URL", "https://unused.test"));
        env.putAll(overrides);
        CheckRunner checks = new CheckRunner(new PrintStream(new ByteArrayOutputStream(), true, StandardCharsets.UTF_8));
        new CertificateChecks(Config.fromEnvironment(env), tls).run(checks);
        return checks.results();
    }

    private static CheckRunner.Result result(List<CheckRunner.Result> results, String id) {
        return results.stream().filter(r -> r.id().equals(id)).findFirst().orElseThrow();
    }

    private static TlsMaterial material(String certificate, String key, String ca) throws Exception {
        return TlsMaterial.load(Fixtures.cert(certificate), Fixtures.cert(key), Fixtures.cert(ca));
    }

    @Test
    void validClientCertificatePassesEveryCheck() throws Exception {
        List<CheckRunner.Result> results = run(Fixtures.clientTls(), Map.of());

        assertEquals(5, results.size());
        for (CheckRunner.Result result : results) {
            assertEquals(CheckRunner.Status.PASS, result.status(), result.id() + ": " + result.detail());
        }
    }

    @Test
    void detectsKeyThatBelongsToAnotherCertificate() throws Exception {
        List<CheckRunner.Result> results = run(material("client.crt", "other-client.key", "ca.crt"), Map.of());

        assertEquals(CheckRunner.Status.FAIL, result(results, "CERT-01").status());
    }

    @Test
    void detectsCertificateFromAnotherCa() throws Exception {
        List<CheckRunner.Result> results = run(material("untrusted-client.crt", "untrusted-client.key", "ca.crt"),
                Map.of());

        assertEquals(CheckRunner.Status.PASS, result(results, "CERT-01").status());
        assertEquals(CheckRunner.Status.FAIL, result(results, "CERT-02").status());
    }

    @Test
    void detectsCertificateExpiringSoonerThanRequired() throws Exception {
        // The fixtures are valid for 100 years; demand more than that.
        List<CheckRunner.Result> results = run(Fixtures.clientTls(), Map.of("MIN_CERT_VALID_DAYS", "40000"));

        CheckRunner.Result validity = result(results, "CERT-03");
        assertEquals(CheckRunner.Status.FAIL, validity.status());
        assertTrue(validity.detail().contains("expires in"));
        assertEquals(CheckRunner.Status.FAIL, result(results, "CERT-05").status());
    }

    @Test
    void detectsCertificateWithoutClientAuthUsage() throws Exception {
        List<CheckRunner.Result> results = run(material("server-only-usage.crt", "server-only-usage.key", "ca.crt"),
                Map.of());

        CheckRunner.Result usage = result(results, "CERT-04");
        assertEquals(CheckRunner.Status.FAIL, usage.status());
        assertTrue(usage.detail().contains("clientAuth"));
    }

    @Test
    void detectsTrustBundleThatContainsALeafCertificate() throws Exception {
        List<CheckRunner.Result> results = run(material("client.crt", "client.key", "other-client.crt"), Map.of());

        CheckRunner.Result ca = result(results, "CERT-05");
        assertEquals(CheckRunner.Status.FAIL, ca.status());
        assertTrue(ca.detail().contains("not a CA"));
    }
}
