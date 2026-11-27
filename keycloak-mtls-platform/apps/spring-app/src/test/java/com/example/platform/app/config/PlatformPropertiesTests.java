package com.example.platform.app.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalArgumentException;

import java.util.List;

import javax.security.auth.x500.X500Principal;

import com.example.platform.app.config.PlatformProperties.Api;
import com.example.platform.app.config.PlatformProperties.App;
import com.example.platform.app.config.PlatformProperties.Keycloak;
import com.example.platform.app.config.PlatformProperties.Oidc;

import org.junit.jupiter.api.Test;

class PlatformPropertiesTests {

    @Test
    void realmUrlsAreBuiltFromBaseUrlsWithoutTrailingSlash() {
        Keycloak keycloak = new Keycloak("https://keycloak.internal:8443/", "https://sso.example.com", "platform");

        assertThat(keycloak.internalRealmUrl()).isEqualTo("https://keycloak.internal:8443/realms/platform");
        assertThat(keycloak.publicRealmUrl()).isEqualTo("https://sso.example.com/realms/platform");
    }

    @Test
    void plainHttpUrlsAreRejected() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new Keycloak("http://keycloak:8080", "https://sso.example.com", "platform"))
                .withMessageContaining("platform.keycloak.internal-url");
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new App("http://app.example.com"))
                .withMessageContaining("platform.app.public-url");
    }

    @Test
    void openidScopeIsMandatory() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new Oidc("spring-app", List.of("profile")))
                .withMessageContaining("openid");
        assertThat(new Oidc("spring-app", List.of("openid", "email")).scopes()).containsExactly("openid", "email");
    }

    @Test
    void requiredRoleMustBeTheKeycloakRoleName() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new Api("spring-app", "ROLE_api-read", ""))
                .withMessageContaining("without the ROLE_ prefix");
    }

    @Test
    void emptyAllowListMeansAnyTrustedCertificate() {
        assertThat(new Api("spring-app", "api-read", "").allowedClientPrincipals()).isEmpty();
        assertThat(new Api("spring-app", "api-read", null).allowedClientPrincipals()).isEmpty();
    }

    @Test
    void allowListIsSplitOnSemicolonsBecauseSubjectsContainCommas() {
        Api api = new Api("spring-app", "api-read",
                "CN=test-client,OU=Platform,O=Example Corp,C=US ; CN=batch,OU=Platform,O=Example Corp,C=US;");

        assertThat(api.allowedClientPrincipals()).containsExactly(
                new X500Principal("CN=test-client,OU=Platform,O=Example Corp,C=US"),
                new X500Principal("CN=batch,OU=Platform,O=Example Corp,C=US"));
    }

    @Test
    void everySectionIsRequired() {
        Keycloak keycloak = new Keycloak("https://kc:8443", "https://kc:8443", "platform");
        App app = new App("https://app:8443");
        Oidc oidc = new Oidc("spring-app", List.of("openid"));

        assertThatIllegalArgumentException()
                .isThrownBy(() -> new PlatformProperties(keycloak, app, oidc, null))
                .withMessageContaining("platform.api");
    }
}
