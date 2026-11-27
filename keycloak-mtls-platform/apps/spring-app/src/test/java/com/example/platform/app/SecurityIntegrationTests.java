package com.example.platform.app;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.allOf;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.startsWith;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.oidcLogin;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.x509;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.redirectedUrlPattern;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.List;
import java.util.Map;

import com.example.platform.app.security.KeycloakRealmRoleConverter;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/**
 * Exercises both security filter chains through MockMvc: what is public, what
 * needs a browser login, and what the API demands (certificate AND token).
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class SecurityIntegrationTests {

    private static final String WHOAMI = "/api/v1/whoami";

    @Autowired
    private MockMvc mvc;

    /** A token as Keycloak issues it for the test-client service account. */
    private static RequestPostProcessor accessToken(String... realmRoles) {
        return jwt()
                .jwt(token -> token
                        .subject("11111111-2222-3333-4444-555555555555")
                        .claim("azp", "test-client")
                        .claim("scope", "profile email")
                        .claim("realm_access", Map.of("roles", List.of(realmRoles)))
                        .claim("cnf", Map.of("x5t#S256", "thumbprint-not-checked-by-the-mock")))
                .authorities(new KeycloakRealmRoleConverter());
    }

    // ---------------------------------------------------------------- public pages

    @Test
    void landingAndLoginPagesArePublicAndOfferBothProtocols() throws Exception {
        for (String path : List.of("/", "/login")) {
            mvc.perform(get(path))
                    .andExpect(status().isOk())
                    .andExpect(content().string(allOf(
                            containsString("/oauth2/authorization/keycloak"),
                            containsString("/saml2/authenticate/keycloak"))));
        }
    }

    @Test
    void protectedPageRedirectsAnonymousUsersToTheLoginPage() throws Exception {
        mvc.perform(get("/me"))
                .andExpect(status().is3xxRedirection())
                .andExpect(redirectedUrlPattern("**/login"));
    }

    @Test
    void signedInOidcUserSeesTheirProfile() throws Exception {
        mvc.perform(get("/me").with(oidcLogin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.protocol").value("oidc"))
                .andExpect(jsonPath("$.name").isNotEmpty());
    }

    // ---------------------------------------------------------------- OIDC wiring

    @Test
    void oidcLoginRedirectsToThePublicKeycloakUrlWithPkce() throws Exception {
        mvc.perform(get("/oauth2/authorization/keycloak"))
                .andExpect(status().is3xxRedirection())
                .andExpect(header().string("Location", allOf(
                        startsWith("https://sso.example.test/realms/platform/protocol/openid-connect/auth?"),
                        containsString("response_type=code"),
                        containsString("client_id=spring-app"),
                        containsString("code_challenge_method=S256"),
                        containsString("code_challenge="),
                        containsString("app.example.test/login/oauth2/code/keycloak"))));
    }

    // ---------------------------------------------------------------- SAML wiring

    @Test
    void samlLoginSendsAnAuthnRequestToTheIdpFromTheMetadata() throws Exception {
        MockHttpServletResponse response = mvc.perform(get("/saml2/authenticate/keycloak")).andReturn().getResponse();

        // POST binding answers 200 with an auto-submitting form, redirect binding answers 302.
        assertThat(response.getStatus()).isIn(200, 302);
        String payload = response.getContentAsString() + " " + response.getHeader("Location");
        assertThat(payload)
                .contains("SAMLRequest")
                .contains("https://localhost:8443/realms/platform/protocol/saml");
    }

    @Test
    void samlServiceProviderMetadataIsPublished() throws Exception {
        mvc.perform(get("/saml2/metadata/keycloak"))
                .andExpect(status().isOk())
                .andExpect(content().string(allOf(
                        containsString("EntityDescriptor"),
                        containsString("https://app.example.test/saml2/service-provider-metadata/keycloak"),
                        containsString("https://app.example.test/login/saml2/sso/keycloak"))));
    }

    // ---------------------------------------------------------------- API: certificate AND token

    @Test
    void apiAcceptsTrustedCertificateWithTokenCarryingTheRole() throws Exception {
        mvc.perform(get(WHOAMI)
                .with(accessToken("api-read"))
                .with(x509(TestCertificates.load(TestCertificates.CLIENT))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.clientId").value("test-client"))
                .andExpect(jsonPath("$.roles[0]").value("api-read"))
                .andExpect(jsonPath("$.certificateSubject").value("CN=test-client,OU=Platform,O=Example Corp,C=US"))
                .andExpect(jsonPath("$.certificateBound").value(true));
    }

    @Test
    void apiRejectsRequestWithoutToken() throws Exception {
        mvc.perform(get(WHOAMI).with(x509(TestCertificates.load(TestCertificates.CLIENT))))
                .andExpect(status().isUnauthorized())
                .andExpect(header().string("WWW-Authenticate", startsWith("Bearer")));
    }

    @Test
    void apiRejectsTokenWithoutClientCertificate() throws Exception {
        mvc.perform(get(WHOAMI).with(accessToken("api-read")))
                .andExpect(status().isForbidden());
    }

    @Test
    void apiRejectsTokenWithoutTheRequiredRole() throws Exception {
        mvc.perform(get(WHOAMI)
                .with(accessToken("some-other-role"))
                .with(x509(TestCertificates.load(TestCertificates.CLIENT))))
                .andExpect(status().isForbidden());
    }

    @Test
    void apiRejectsCertificateThatIsNotOnTheAllowList() throws Exception {
        mvc.perform(get(WHOAMI)
                .with(accessToken("api-read"))
                .with(x509(TestCertificates.load(TestCertificates.OTHER_CLIENT))))
                .andExpect(status().isForbidden());
    }

    @Test
    void browserSessionCannotCallTheApi() throws Exception {
        mvc.perform(get(WHOAMI)
                .with(oidcLogin())
                .with(x509(TestCertificates.load(TestCertificates.CLIENT))))
                .andExpect(status().isForbidden());
    }

    // ---------------------------------------------------------------- actuator

    @Test
    void healthIsPublicButOtherActuatorEndpointsAreDenied() throws Exception {
        mvc.perform(get("/actuator/health")).andExpect(status().isOk());
        mvc.perform(get("/actuator/env").with(user("alice"))).andExpect(status().isForbidden());
    }
}
