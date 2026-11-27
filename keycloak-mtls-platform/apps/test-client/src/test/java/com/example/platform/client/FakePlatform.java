package com.example.platform.client;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.Optional;

import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLPeerUnverifiedException;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsExchange;
import com.sun.net.httpserver.HttpsParameters;
import com.sun.net.httpserver.HttpsServer;

/**
 * In-process stand-in for Keycloak AND the Spring app, served over real TLS
 * with optional client certificates (like {@code https-client-auth=request} /
 * {@code client-auth: want}). It implements just enough of both to exercise
 * every check, and has switches to misbehave so the negative paths can be tested.
 */
final class FakePlatform implements AutoCloseable {

    /** When false the token endpoint issues tokens to anyone (a misconfigured client). */
    volatile boolean tokenEndpointRequiresCertificate = true;
    /** When false the API accepts a token without a client certificate (mTLS not enforced). */
    volatile boolean apiRequiresCertificate = true;
    /** Audience placed in issued tokens. */
    volatile String audience = "spring-app";
    /** When false issued tokens carry no {@code cnf} claim. */
    volatile boolean bindTokensToCertificate = true;
    /** When false the OIDC redirect omits the PKCE parameters. */
    volatile boolean pkce = true;

    private final HttpsServer server;
    private final TestTokens tokens;
    private final String baseUrl;

    FakePlatform() throws Exception {
        tokens = TestTokens.rsa("fake-key");
        server = HttpsServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setHttpsConfigurator(new HttpsConfigurator(Fixtures.serverTls().mutualTlsContext()) {
            @Override
            public void configure(HttpsParameters parameters) {
                SSLParameters ssl = getSSLContext().getDefaultSSLParameters();
                ssl.setWantClientAuth(true);
                parameters.setSSLParameters(ssl);
            }
        });
        baseUrl = "https://localhost:" + server.getAddress().getPort();

        // --- Keycloak
        route("/realms/platform/.well-known/openid-configuration", exchange -> json(exchange, 200, """
                {"issuer":"%1$s","authorization_endpoint":"%1$s/protocol/openid-connect/auth",
                 "token_endpoint":"%1$s/protocol/openid-connect/token","jwks_uri":"%1$s/protocol/openid-connect/certs",
                 "userinfo_endpoint":"%1$s/protocol/openid-connect/userinfo",
                 "token_endpoint_auth_methods_supported":["client_secret_basic","tls_client_auth"],
                 "tls_client_certificate_bound_access_tokens":true}
                """.formatted(issuer())));
        route("/realms/platform/protocol/openid-connect/certs", exchange -> json(exchange, 200, tokens.jwksJson()));
        route("/realms/platform/protocol/openid-connect/token", this::token);
        route("/realms/platform/protocol/saml/descriptor", exchange -> respond(exchange, 200, "application/xml",
                idpMetadata()));
        route("/health/ready", exchange -> json(exchange, 200, "{\"status\":\"UP\",\"checks\":[]}"));

        // --- Spring app
        route("/actuator/health/readiness", exchange -> json(exchange, 200, "{\"status\":\"UP\"}"));
        route("/api/v1/whoami", this::whoAmI);
        route("/oauth2/authorization/keycloak", exchange -> redirect(exchange,
                issuer() + "/protocol/openid-connect/auth?response_type=code&client_id=spring-app"
                        + "&scope=openid%20profile&state=s1&nonce=n1&redirect_uri=" + baseUrl
                        + "/login/oauth2/code/keycloak"
                        + (pkce ? "&code_challenge=abc&code_challenge_method=S256" : "")));
        route("/saml2/authenticate/keycloak", exchange -> respond(exchange, 200, "text/html", """
                <!DOCTYPE html><html><body>
                <form id="redirect-form" method="POST" action="%s/protocol/saml">
                <input name="SAMLRequest" type="hidden" value="%s" />
                <input name="RelayState" type="hidden" value="r1" />
                </form></body></html>
                """.formatted(issuer(), Base64.getEncoder().encodeToString("""
                <saml2p:AuthnRequest xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" ID="a1">
                <ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:SignatureValue>c2ln</ds:SignatureValue>
                </ds:Signature></saml2p:AuthnRequest>""".getBytes(StandardCharsets.UTF_8)))));
        route("/saml2/metadata/keycloak", exchange -> respond(exchange, 200, "application/xml", """
                <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="%1$s/sp">
                <md:SPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
                <md:AssertionConsumerService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
                    Location="%1$s/login/saml2/sso/keycloak" index="1"/>
                </md:SPSSODescriptor></md:EntityDescriptor>
                """.formatted(baseUrl)));
        route("/me", exchange -> redirect(exchange, "/login"));
        route("/", exchange -> respond(exchange, 200, "text/html", "<html><body>login</body></html>"));
        server.start();
    }

    String baseUrl() {
        return baseUrl;
    }

    String issuer() {
        return baseUrl + "/realms/platform";
    }

    /** Environment that points every URL of the test client at this fake. */
    Map<String, String> environment() {
        Map<String, String> env = Fixtures.environment(baseUrl);
        env.put("KEYCLOAK_MGMT_URL", baseUrl);
        env.put("APP_URL", baseUrl);
        env.put("APP_MGMT_URL", baseUrl);
        return env;
    }

    @Override
    public void close() {
        server.stop(0);
    }

    private void token(HttpExchange exchange) throws IOException {
        Optional<X509Certificate> certificate = clientCertificate(exchange);
        String form = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        if (!form.contains("grant_type=client_credentials")
                || (tokenEndpointRequiresCertificate && certificate.isEmpty())) {
            json(exchange, 401, "{\"error\":\"invalid_client\",\"error_description\":\"Invalid client credentials\"}");
            return;
        }
        try {
            String confirmation = bindTokensToCertificate && certificate.isPresent()
                    ? ",\"cnf\":{\"x5t#S256\":\"" + TlsMaterial.thumbprint(certificate.get()) + "\"}"
                    : "";
            String claims = """
                    {"iss":"%s","aud":"%s","azp":"test-client","sub":"service-account","exp":%d,
                     "realm_access":{"roles":["api-read"]}%s}
                    """.formatted(issuer(), audience, Instant.now().plusSeconds(120).getEpochSecond(), confirmation);
            json(exchange, 200, "{\"access_token\":\"" + tokens.sign(claims)
                    + "\",\"token_type\":\"Bearer\",\"expires_in\":120}");
        } catch (Exception e) {
            throw new IOException(e);
        }
    }

    private void whoAmI(HttpExchange exchange) throws IOException {
        String authorization = exchange.getRequestHeaders().getFirst("Authorization");
        if (authorization == null || !authorization.startsWith("Bearer ")) {
            exchange.getResponseHeaders().add("WWW-Authenticate", "Bearer");
            json(exchange, 401, "{}");
            return;
        }
        boolean validSignature;
        try {
            validSignature = Jwt.parse(authorization.substring("Bearer ".length())).verifySignature(tokens.jwks());
        } catch (Exception e) {
            validSignature = false;
        }
        if (!validSignature) {
            exchange.getResponseHeaders().add("WWW-Authenticate", "Bearer error=\"invalid_token\"");
            json(exchange, 401, "{}");
            return;
        }
        Optional<X509Certificate> certificate = clientCertificate(exchange);
        if (apiRequiresCertificate && certificate.isEmpty()) {
            json(exchange, 403, "{}");
            return;
        }
        json(exchange, 200, """
                {"subject":"service-account","clientId":"test-client","roles":["api-read"],
                 "certificateSubject":"%s","certificateBound":true}
                """.formatted(certificate.map(c -> c.getSubjectX500Principal().getName()).orElse("")));
    }

    private String idpMetadata() {
        try {
            String certificate = Base64.getEncoder()
                    .encodeToString(Fixtures.serverTls().clientCertificate().getEncoded());
            return """
                    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="%1$s">
                    <md:IDPSSODescriptor WantAuthnRequestsSigned="true"
                        protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
                    <md:KeyDescriptor use="signing"><ds:KeyInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
                    <ds:X509Data><ds:X509Certificate>%2$s</ds:X509Certificate></ds:X509Data></ds:KeyInfo>
                    </md:KeyDescriptor>
                    <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
                        Location="%1$s/protocol/saml"/>
                    <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
                        Location="%1$s/protocol/saml"/>
                    </md:IDPSSODescriptor></md:EntityDescriptor>
                    """.formatted(issuer(), certificate);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static Optional<X509Certificate> clientCertificate(HttpExchange exchange) {
        try {
            Certificate[] chain = ((HttpsExchange) exchange).getSSLSession().getPeerCertificates();
            return Optional.of((X509Certificate) chain[0]);
        } catch (SSLPeerUnverifiedException e) {
            return Optional.empty();
        }
    }

    @FunctionalInterface
    private interface Handler {
        void handle(HttpExchange exchange) throws IOException;
    }

    private void route(String path, Handler handler) {
        server.createContext(path, exchange -> {
            try (exchange) {
                // createContext matches by prefix; only the exact path is served.
                if (exchange.getRequestURI().getPath().equals(path)) {
                    handler.handle(exchange);
                } else {
                    respond(exchange, 404, "text/plain", "not found");
                }
            }
        });
    }

    private static void json(HttpExchange exchange, int status, String body) throws IOException {
        respond(exchange, status, "application/json", body);
    }

    private static void redirect(HttpExchange exchange, String location) throws IOException {
        exchange.getResponseHeaders().add("Location", location);
        exchange.sendResponseHeaders(302, -1);
    }

    private static void respond(HttpExchange exchange, int status, String contentType, String body)
            throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", contentType);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }
}
