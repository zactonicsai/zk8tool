package com.example.platform.client;

import static com.example.platform.client.CheckRunner.require;

import java.io.IOException;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.w3c.dom.Document;
import org.w3c.dom.Element;

/**
 * Checks against the Spring Boot app: TLS, health, the mTLS + bearer-token
 * API (positive and negative cases) and that the OIDC and SAML login flows
 * are wired to Keycloak.
 */
final class AppChecks {

    private static final Pattern SAML_REQUEST_INPUT = Pattern.compile(
            "name=\"SAMLRequest\"[^>]*value=\"([^\"]*)\"|value=\"([^\"]*)\"[^>]*name=\"SAMLRequest\"");
    private static final Pattern FORM_ACTION = Pattern.compile("<form[^>]*action=\"([^\"]*)\"");

    private final Config config;
    private final URI appUrl;
    private final Http mutualTls;
    private final Http serverAuthOnly;
    private final KeycloakChecks keycloak;

    AppChecks(Config config, Http mutualTls, Http serverAuthOnly, KeycloakChecks keycloak) {
        this.config = config;
        this.appUrl = config.appUrl().orElseThrow();
        this.mutualTls = mutualTls;
        this.serverAuthOnly = serverAuthOnly;
        this.keycloak = keycloak;
    }

    void run(CheckRunner checks) {
        checks.check("APP-01", "App answers over TLS with a trusted, valid server certificate", this::reachable);
        if (config.appMgmtUrl().isPresent()) {
            checks.check("APP-02", "App reports ready on the management port", this::health);
        } else {
            checks.skip("APP-02", "App reports ready on the management port", "APP_MGMT_URL not set");
        }
        checks.check("APP-03", "API accepts client certificate + certificate-bound access token", this::apiAuthorized);
        checks.check("APP-04", "API rejects a request without an access token", this::apiWithoutToken);
        checks.check("APP-05", "API rejects a request without a client certificate", this::apiWithoutCertificate);
        checks.check("APP-06", "API rejects a tampered access token", this::apiTamperedToken);
        checks.check("APP-07", "OIDC login redirects to Keycloak with PKCE", this::oidcRedirect);
        checks.check("APP-08", "SAML login sends an AuthnRequest to Keycloak", this::samlAuthnRequest);
        checks.check("APP-09", "SAML SP metadata is published", this::samlSpMetadata);
        checks.check("APP-10", "Protected page redirects anonymous users to the login page", this::loginRedirect);
    }

    private URI app(String path) {
        return URI.create(appUrl + path);
    }

    private String token() {
        return keycloak.accessToken()
                .orElseThrow(() -> new CheckRunner.CheckSkippedException("no access token (KC-05 failed or skipped)"));
    }

    private static Map<String, String> bearer(String token) {
        return Map.of("Authorization", "Bearer " + token, "Accept", "application/json");
    }

    private String reachable() throws Exception {
        URI uri = app("/");
        Wire.await("App (" + uri + ")", config.waitTimeout(), () -> {
            int status = mutualTls.get(uri).status();
            return status < 500 ? null : "HTTP " + status;
        });
        return Wire.tlsSummary("App", mutualTls.get(uri), config);
    }

    private String health() throws Exception {
        URI uri = URI.create(config.appMgmtUrl().orElseThrow() + "/actuator/health/readiness");
        Http.Response response = serverAuthOnly.get(uri);
        require(response.status() == 200, uri + " returned HTTP " + response.status());
        String status = Json.string(Json.parseObject(response.body()), "status");
        require("UP".equals(status), "App readiness is " + status);
        return "status UP";
    }

    private String apiAuthorized() throws Exception {
        Http.Response response = mutualTls.get(app("/api/v1/whoami"), bearer(token()));
        require(response.status() == 200, "Expected HTTP 200 but got " + response.status() + ": " + response.body());
        Map<String, Object> body = Json.parseObject(response.body());
        require(config.clientId().equals(Json.string(body, "clientId")),
                "clientId is '" + body.get("clientId") + "', expected '" + config.clientId() + "'");
        require(Boolean.TRUE.equals(body.get("certificateBound")), "The app did not see a certificate-bound token");
        return "subject " + body.get("subject") + ", certificate " + body.get("certificateSubject");
    }

    private String apiWithoutToken() throws Exception {
        Http.Response response = mutualTls.get(app("/api/v1/whoami"), Map.of("Accept", "application/json"));
        require(response.status() == 401, "Expected HTTP 401 without a token but got " + response.status());
        return "HTTP 401, " + response.header("WWW-Authenticate").orElse("no WWW-Authenticate header");
    }

    private String apiWithoutCertificate() throws Exception {
        Http.Response response;
        try {
            response = serverAuthOnly.get(app("/api/v1/whoami"), bearer(token()));
        } catch (IOException e) {
            // server.ssl.client-auth=need: the handshake itself fails, which is the strictest outcome.
            return "TLS handshake refused: " + CheckRunner.describe(e);
        }
        require(response.status() == 401 || response.status() == 403,
                "Expected HTTP 401/403 without a client certificate but got " + response.status()
                        + ": the API does NOT enforce mutual TLS");
        return "HTTP " + response.status();
    }

    private String apiTamperedToken() throws Exception {
        String token = token();
        // Flip one character in the middle of the signature. (The LAST base64url
        // character also encodes padding bits, so changing it can leave the bytes intact.)
        int index = token.lastIndexOf('.') + 1 + (token.length() - token.lastIndexOf('.') - 1) / 2;
        char replacement = token.charAt(index) == 'A' ? 'B' : 'A';
        String tampered = token.substring(0, index) + replacement + token.substring(index + 1);
        Http.Response response = mutualTls.get(app("/api/v1/whoami"), bearer(tampered));
        require(response.status() == 401, "Expected HTTP 401 for a tampered token but got " + response.status());
        return "HTTP 401";
    }

    private String oidcRedirect() throws Exception {
        Http.Response response = mutualTls.get(app("/oauth2/authorization/" + config.appRegistration()));
        require(response.status() == 302, "Expected HTTP 302 but got " + response.status());
        String location = response.header("Location").orElse("");
        String authorizationEndpoint = config.expectedIssuer() + "/protocol/openid-connect/auth";
        require(location.startsWith(authorizationEndpoint + "?"),
                "Redirect goes to '" + location + "' instead of " + authorizationEndpoint);
        Map<String, String> query = query(URI.create(location));
        require("code".equals(query.get("response_type")), "response_type is not 'code'");
        require(query.containsKey("client_id"), "client_id missing");
        require(query.getOrDefault("scope", "").contains("openid"), "scope does not contain 'openid'");
        require("S256".equals(query.get("code_challenge_method")) && query.containsKey("code_challenge"),
                "PKCE (code_challenge with S256) is missing");
        require(query.containsKey("state") && query.containsKey("nonce"), "state and nonce must be present");
        return "client_id " + query.get("client_id") + ", redirect_uri " + query.get("redirect_uri");
    }

    private String samlAuthnRequest() throws Exception {
        Http.Response response = mutualTls.get(app("/saml2/authenticate/" + config.appRegistration()));
        List<String> ssoLocations = keycloak.samlSsoLocations();
        String target;
        String encoded;
        boolean redirectBinding = response.status() == 302;
        if (redirectBinding) {
            URI location = URI.create(response.header("Location").orElse(""));
            target = location.toString().replaceFirst("\\?.*$", "");
            encoded = query(location).get("SAMLRequest");
        } else {
            require(response.status() == 200, "Expected HTTP 200 (POST binding) or 302 (redirect binding) but got "
                    + response.status());
            Matcher action = FORM_ACTION.matcher(response.body());
            require(action.find(), "No <form action> in the POST-binding page");
            target = unescapeHtml(action.group(1));
            Matcher input = SAML_REQUEST_INPUT.matcher(response.body());
            require(input.find(), "No SAMLRequest field in the POST-binding page");
            encoded = unescapeHtml(Optional.ofNullable(input.group(1)).orElse(input.group(2)));
        }
        require(encoded != null && !encoded.isBlank(), "SAMLRequest is empty");
        if (ssoLocations.isEmpty()) {
            require(target.startsWith(config.expectedIssuer()),
                    "AuthnRequest target '" + target + "' is not under " + config.expectedIssuer());
        } else {
            require(ssoLocations.contains(target),
                    "AuthnRequest target '" + target + "' is not one of the IdP SSO endpoints " + ssoLocations);
        }
        String detail = (redirectBinding ? "redirect" : "POST") + " binding to " + target;
        if (!redirectBinding) {
            // POST binding carries plain base64 XML; redirect binding is DEFLATE-compressed and signed in the query.
            String xml = decodeLeniently(encoded);
            if (xml != null) {
                require(xml.contains("AuthnRequest"), "SAMLRequest does not contain an AuthnRequest");
                detail += xml.contains("SignatureValue") ? ", signed" : ", NOT signed";
            }
        }
        return detail;
    }

    private String samlSpMetadata() throws Exception {
        Http.Response response = mutualTls.get(app("/saml2/metadata/" + config.appRegistration()));
        require(response.status() == 200, "Expected HTTP 200 but got " + response.status());
        Document document = Wire.parseXml(response.body());
        Element root = document.getDocumentElement();
        require("EntityDescriptor".equals(root.getLocalName()), "Root element is not md:EntityDescriptor");
        require(!Wire.elements(document, Wire.SAML_METADATA_NS, "SPSSODescriptor").isEmpty(), "No SPSSODescriptor");
        List<Element> consumers = Wire.elements(document, Wire.SAML_METADATA_NS, "AssertionConsumerService");
        require(!consumers.isEmpty(), "No AssertionConsumerService");
        return "entityID " + root.getAttribute("entityID") + ", ACS " + consumers.getFirst().getAttribute("Location");
    }

    private String loginRedirect() throws Exception {
        Http.Response response = mutualTls.get(app("/me"), Map.of("Accept", "text/html"));
        require(response.status() == 302, "Expected HTTP 302 but got " + response.status());
        String location = response.header("Location").orElse("");
        require(location.endsWith("/login"), "Redirect goes to '" + location + "' instead of /login");
        return "redirects to " + location;
    }

    static Map<String, String> query(URI uri) {
        Map<String, String> parameters = new java.util.LinkedHashMap<>();
        String raw = uri.getRawQuery();
        if (raw == null) {
            return parameters;
        }
        for (String pair : raw.split("&")) {
            int equals = pair.indexOf('=');
            String name = equals < 0 ? pair : pair.substring(0, equals);
            String value = equals < 0 ? "" : pair.substring(equals + 1);
            parameters.put(URLDecoder.decode(name, StandardCharsets.UTF_8),
                    URLDecoder.decode(value, StandardCharsets.UTF_8));
        }
        return parameters;
    }

    static String unescapeHtml(String value) {
        return value.replace("&#43;", "+").replace("&#x2B;", "+").replace("&#61;", "=").replace("&#x3D;", "=")
                .replace("&#47;", "/").replace("&#x2F;", "/").replace("&quot;", "\"").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&amp;", "&");
    }

    private static String decodeLeniently(String encoded) {
        try {
            String candidate = encoded.contains("%") ? URLDecoder.decode(encoded, StandardCharsets.UTF_8) : encoded;
            return new String(Base64.getMimeDecoder().decode(candidate), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }
}
