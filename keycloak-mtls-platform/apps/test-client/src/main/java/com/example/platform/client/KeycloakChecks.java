package com.example.platform.client;

import static com.example.platform.client.CheckRunner.require;
import static com.example.platform.client.CheckRunner.requirePresent;

import java.io.ByteArrayInputStream;
import java.net.URI;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import org.w3c.dom.Document;
import org.w3c.dom.Element;

/**
 * Checks against Keycloak: TLS, OpenID Connect discovery, the mTLS
 * client-credentials grant, the access token itself and the SAML IdP metadata.
 */
final class KeycloakChecks {

    private static final String POST_BINDING = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST";

    private final Config config;
    private final Http mutualTls;
    private final Http serverAuthOnly;
    private final TlsMaterial tls;

    private Map<String, Object> jwks;
    private String accessToken;
    private Jwt jwt;
    private final List<String> samlSsoLocations = new ArrayList<>();

    KeycloakChecks(Config config, Http mutualTls, Http serverAuthOnly, TlsMaterial tls) {
        this.config = config;
        this.mutualTls = mutualTls;
        this.serverAuthOnly = serverAuthOnly;
        this.tls = tls;
    }

    /** The access token obtained by KC-05, when that check passed. */
    Optional<String> accessToken() {
        return Optional.ofNullable(accessToken);
    }

    /** SingleSignOnService locations found in the IdP metadata by KC-10. */
    List<String> samlSsoLocations() {
        return List.copyOf(samlSsoLocations);
    }

    void run(CheckRunner checks) {
        checks.check("KC-01", "Keycloak answers over TLS with a trusted, valid server certificate", this::reachable);
        if (config.keycloakMgmtUrl().isPresent()) {
            checks.check("KC-02", "Keycloak reports ready on the management interface", this::health);
        } else {
            checks.skip("KC-02", "Keycloak reports ready on the management interface", "KEYCLOAK_MGMT_URL not set");
        }
        checks.check("KC-03", "OIDC discovery advertises the expected issuer and mTLS client authentication",
                this::discovery);
        checks.check("KC-04", "JWK Set is served and contains signing keys", this::jwks);
        checks.check("KC-05", "Client-credentials grant succeeds with mTLS client authentication", this::token);
        checks.check("KC-06", "Token endpoint rejects the same request without a client certificate",
                this::tokenWithoutCertificate);
        checks.check("KC-07", "Access token signature, issuer, audience and expiry are valid", this::tokenClaims);
        checks.check("KC-08", "Access token is bound to the client certificate (cnf.x5t#S256)", this::tokenBinding);
        checks.check("KC-09", "Access token carries the expected realm role", this::tokenRole);
        checks.check("KC-10", "SAML IdP metadata is well formed with a valid signing certificate", this::samlMetadata);
    }

    private URI realm(String path) {
        return URI.create(config.realmUrl() + path);
    }

    private String reachable() throws Exception {
        URI uri = realm("/.well-known/openid-configuration");
        Wire.await("Keycloak (" + uri + ")", config.waitTimeout(), () -> {
            int status = mutualTls.get(uri).status();
            return status == 200 ? null : "HTTP " + status;
        });
        return Wire.tlsSummary("Keycloak", mutualTls.get(uri), config);
    }

    private String health() throws Exception {
        URI uri = URI.create(config.keycloakMgmtUrl().orElseThrow() + "/health/ready");
        Http.Response response = serverAuthOnly.get(uri);
        require(response.status() == 200, uri + " returned HTTP " + response.status());
        String status = Json.string(Json.parseObject(response.body()), "status");
        require("UP".equals(status), "Keycloak health status is " + status);
        return "status UP";
    }

    private String discovery() throws Exception {
        Http.Response response = mutualTls.get(realm("/.well-known/openid-configuration"));
        require(response.status() == 200, "Discovery returned HTTP " + response.status());
        Map<String, Object> document = Json.parseObject(response.body());
        String issuer = Json.string(document, "issuer");
        require(config.expectedIssuer().equals(issuer),
                "Issuer is '" + issuer + "' but '" + config.expectedIssuer() + "' was expected. "
                        + "Check KC_HOSTNAME / keycloak.publicUrl.");
        for (String endpoint : List.of("authorization_endpoint", "token_endpoint", "jwks_uri", "userinfo_endpoint")) {
            String value = Json.string(document, endpoint);
            require(value != null && value.startsWith("https://"), endpoint + " is not an https URL: " + value);
        }
        require(Json.stringList(document.get("token_endpoint_auth_methods_supported")).contains("tls_client_auth"),
                "tls_client_auth is not among token_endpoint_auth_methods_supported");
        require(Boolean.TRUE.equals(document.get("tls_client_certificate_bound_access_tokens")),
                "tls_client_certificate_bound_access_tokens is not true");
        return "issuer " + issuer;
    }

    private String jwks() throws Exception {
        Http.Response response = mutualTls.get(realm("/protocol/openid-connect/certs"));
        require(response.status() == 200, "JWK Set returned HTTP " + response.status());
        Map<String, Object> document = Json.parseObject(response.body());
        List<Object> keys = Json.asArray(document.getOrDefault("keys", List.of()));
        long signingKeys = keys.stream().map(Json::asObject)
                .filter(key -> !"enc".equals(Json.string(key, "use"))).count();
        require(signingKeys > 0, "JWK Set contains no signing key");
        jwks = document;
        return signingKeys + " signing key(s)";
    }

    private Http.Response requestToken(Http http) throws Exception {
        return http.postForm(realm("/protocol/openid-connect/token"),
                Map.of("grant_type", "client_credentials", "client_id", config.clientId()));
    }

    private String token() throws Exception {
        Http.Response response = requestToken(mutualTls);
        require(response.status() == 200, "Token endpoint returned HTTP " + response.status() + ": "
                + response.body() + ". Check the client's x509.subjectdn against the certificate subject "
                + tls.clientCertificate().getSubjectX500Principal().getName());
        Map<String, Object> body = Json.parseObject(response.body());
        String token = Json.string(body, "access_token");
        require(token != null && !token.isBlank(), "Response contains no access_token");
        require("Bearer".equalsIgnoreCase(Json.string(body, "token_type")), "token_type is not Bearer");
        jwt = Jwt.parse(token);
        accessToken = token;
        return "client " + config.clientId() + ", expires in " + body.get("expires_in") + " s";
    }

    private String tokenWithoutCertificate() throws Exception {
        Http.Response response = requestToken(serverAuthOnly);
        require(response.status() == 400 || response.status() == 401,
                "Expected HTTP 400/401 without a client certificate but got " + response.status()
                        + ": client authentication is NOT enforced");
        String error = Json.string(Json.parseObject(response.body()), "error");
        return "rejected with HTTP " + response.status() + " (" + error + ")";
    }

    private String tokenClaims() throws Exception {
        Jwt token = requirePresent(jwt, "no access token (KC-05 failed)");
        Map<String, Object> keys = requirePresent(jwks, "no JWK Set (KC-04 failed)");
        require(token.verifySignature(keys), "Signature does not verify against the JWK Set (kid " + token.keyId() + ")");
        require(config.expectedIssuer().equals(token.issuer()),
                "iss is '" + token.issuer() + "', expected '" + config.expectedIssuer() + "'");
        require(config.clientId().equals(token.authorizedParty()),
                "azp is '" + token.authorizedParty() + "', expected '" + config.clientId() + "'");
        require(token.audience().contains(config.expectedAudience()),
                "aud " + token.audience() + " does not contain '" + config.expectedAudience() + "'");
        Instant expiry = token.expiresAt();
        require(expiry != null && expiry.isAfter(Instant.now()), "Token is expired or has no exp claim: " + expiry);
        return token.algorithm() + " signature valid, aud " + token.audience();
    }

    private String tokenBinding() throws Exception {
        Jwt token = requirePresent(jwt, "no access token (KC-05 failed)");
        String expected = tls.clientCertificateThumbprint();
        String actual = token.certificateThumbprint();
        require(actual != null, "Token has no cnf.x5t#S256 claim: enable "
                + "'OAuth 2.0 Mutual TLS Certificate Bound Access Tokens' on client " + config.clientId());
        require(expected.equals(actual), "cnf.x5t#S256 is " + actual + " but the client certificate hashes to " + expected);
        return "x5t#S256 " + actual;
    }

    private String tokenRole() {
        Jwt token = requirePresent(jwt, "no access token (KC-05 failed)");
        require(token.realmRoles().contains(config.expectedRole()),
                "realm_access.roles " + token.realmRoles() + " does not contain '" + config.expectedRole() + "'");
        return "roles " + token.realmRoles();
    }

    private String samlMetadata() throws Exception {
        Http.Response response = mutualTls.get(realm("/protocol/saml/descriptor"));
        require(response.status() == 200, "SAML descriptor returned HTTP " + response.status());
        Document document = Wire.parseXml(response.body());
        Element root = document.getDocumentElement();
        require("EntityDescriptor".equals(root.getLocalName()) && Wire.SAML_METADATA_NS.equals(root.getNamespaceURI()),
                "Root element is not md:EntityDescriptor");
        require(config.expectedIssuer().equals(root.getAttribute("entityID")),
                "entityID is '" + root.getAttribute("entityID") + "', expected '" + config.expectedIssuer() + "'");
        require(!Wire.elements(document, Wire.SAML_METADATA_NS, "IDPSSODescriptor").isEmpty(),
                "No IDPSSODescriptor in the metadata");

        List<Element> certificates = Wire.elements(document, Wire.XML_DSIG_NS, "X509Certificate");
        require(!certificates.isEmpty(), "No signing certificate in the metadata");
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        String validity = "";
        for (Element element : certificates) {
            byte[] der = Base64.getMimeDecoder().decode(element.getTextContent().strip());
            X509Certificate certificate = (X509Certificate) factory.generateCertificate(new ByteArrayInputStream(der));
            validity = CertificateChecks.validity("SAML signing", certificate, config.minValidity());
        }

        samlSsoLocations.clear();
        boolean postBinding = false;
        for (Element service : Wire.elements(document, Wire.SAML_METADATA_NS, "SingleSignOnService")) {
            String location = service.getAttribute("Location");
            require(location.startsWith("https://"), "SingleSignOnService location is not https: " + location);
            samlSsoLocations.add(location);
            postBinding |= POST_BINDING.equals(service.getAttribute("Binding"));
        }
        require(postBinding, "No SingleSignOnService with HTTP-POST binding");
        return samlSsoLocations.size() + " SSO endpoint(s); " + validity;
    }
}
