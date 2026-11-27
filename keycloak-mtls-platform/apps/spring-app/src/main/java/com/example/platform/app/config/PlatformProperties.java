package com.example.platform.app.config;

import java.util.Arrays;
import java.util.List;

import javax.security.auth.x500.X500Principal;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.util.Assert;

/**
 * Typed view of the {@code platform.*} properties in {@code application.yaml}.
 * Invalid or missing values fail at start-up with a message naming the property.
 */
@ConfigurationProperties("platform")
public record PlatformProperties(Keycloak keycloak, App app, Oidc oidc, Api api) {

    public PlatformProperties {
        Assert.notNull(keycloak, "platform.keycloak.* must be configured");
        Assert.notNull(app, "platform.app.* must be configured");
        Assert.notNull(oidc, "platform.oidc.* must be configured");
        Assert.notNull(api, "platform.api.* must be configured");
    }

    /**
     * @param internalUrl base URL for back-channel calls from this app
     * @param publicUrl   base URL used by browsers; also the token issuer
     * @param realm       Keycloak realm
     */
    public record Keycloak(String internalUrl, String publicUrl, String realm) {

        public Keycloak {
            internalUrl = httpsUrl("platform.keycloak.internal-url", internalUrl);
            publicUrl = httpsUrl("platform.keycloak.public-url", publicUrl);
            Assert.hasText(realm, "platform.keycloak.realm must not be empty");
        }

        public String internalRealmUrl() {
            return internalUrl + "/realms/" + realm;
        }

        public String publicRealmUrl() {
            return publicUrl + "/realms/" + realm;
        }
    }

    /** @param publicUrl browser-facing base URL of this application */
    public record App(String publicUrl) {

        public App {
            publicUrl = httpsUrl("platform.app.public-url", publicUrl);
        }
    }

    /**
     * @param clientId OIDC client id registered in Keycloak
     * @param scopes   requested scopes; must contain {@code openid}
     */
    public record Oidc(String clientId, List<String> scopes) {

        public Oidc {
            Assert.hasText(clientId, "platform.oidc.client-id must not be empty");
            scopes = (scopes == null) ? List.of() : List.copyOf(scopes);
            Assert.isTrue(scopes.contains("openid"), "platform.oidc.scopes must contain 'openid'");
        }
    }

    /**
     * @param audience              audience a token needs for {@code /api/**}
     * @param requiredRole          realm role a token needs for {@code /api/**}
     * @param allowedClientSubjects optional {@code ;}-separated allow-list of client certificate subject DNs
     */
    public record Api(String audience, String requiredRole, String allowedClientSubjects) {

        public Api {
            Assert.hasText(audience, "platform.api.audience must not be empty");
            Assert.hasText(requiredRole, "platform.api.required-role must not be empty");
            Assert.isTrue(!requiredRole.startsWith("ROLE_"),
                    "platform.api.required-role is the Keycloak role name, without the ROLE_ prefix");
        }

        /**
         * Parsed allow-list. Subject DNs contain commas, hence the {@code ;}
         * separator. An empty list means "any certificate from the trusted CA".
         */
        public List<X500Principal> allowedClientPrincipals() {
            if (allowedClientSubjects == null || allowedClientSubjects.isBlank()) {
                return List.of();
            }
            return Arrays.stream(allowedClientSubjects.split(";"))
                    .map(String::strip)
                    .filter(dn -> !dn.isEmpty())
                    .map(X500Principal::new)
                    .toList();
        }
    }

    private static String httpsUrl(String property, String value) {
        Assert.hasText(value, property + " must not be empty");
        Assert.isTrue(value.startsWith("https://"), property + " must be an https:// URL but was: " + value);
        return value.endsWith("/") ? value.substring(0, value.length() - 1) : value;
    }
}
