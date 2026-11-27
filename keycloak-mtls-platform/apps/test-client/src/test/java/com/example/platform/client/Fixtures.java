package com.example.platform.client;

import java.net.URISyntaxException;
import java.net.URL;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/** Paths of the committed certificate fixtures (src/test/resources/certs). */
final class Fixtures {

    private Fixtures() {
    }

    static Path cert(String name) {
        URL url = Fixtures.class.getResource("/certs/" + name);
        if (url == null) {
            throw new IllegalStateException("Missing test fixture certs/" + name
                    + " (run tests/fixtures/generate-test-certs.sh)");
        }
        try {
            return Path.of(url.toURI());
        } catch (URISyntaxException e) {
            throw new IllegalStateException(e);
        }
    }

    /** Client identity CN=test-client issued by the trusted test CA. */
    static TlsMaterial clientTls() throws Exception {
        return TlsMaterial.load(cert("client.crt"), cert("client.key"), cert("ca.crt"));
    }

    /** Server identity CN=localhost (SAN localhost, 127.0.0.1) issued by the trusted test CA. */
    static TlsMaterial serverTls() throws Exception {
        return TlsMaterial.load(cert("server.crt"), cert("server.key"), cert("ca.crt"));
    }

    /** Minimal valid environment for {@link Config#fromEnvironment(Map)}; tests add or override entries. */
    static Map<String, String> environment(String baseUrl) {
        Map<String, String> env = new HashMap<>();
        env.put("KEYCLOAK_URL", baseUrl);
        env.put("TLS_CERT_FILE", cert("client.crt").toString());
        env.put("TLS_KEY_FILE", cert("client.key").toString());
        env.put("TLS_CA_FILE", cert("ca.crt").toString());
        env.put("WAIT_TIMEOUT_SECONDS", "0");
        env.put("HTTP_TIMEOUT_SECONDS", "5");
        return env;
    }
}
