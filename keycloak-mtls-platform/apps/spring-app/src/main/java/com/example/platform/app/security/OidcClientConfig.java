package com.example.platform.app.security;

import java.util.Map;

import com.example.platform.app.config.PlatformProperties;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.oauth2.client.endpoint.OAuth2AccessTokenResponseClient;
import org.springframework.security.oauth2.client.endpoint.OAuth2AuthorizationCodeGrantRequest;
import org.springframework.security.oauth2.client.endpoint.RestClientAuthorizationCodeTokenResponseClient;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.registration.InMemoryClientRegistrationRepository;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.ClientAuthenticationMethod;
import org.springframework.util.LinkedMultiValueMap;

/**
 * OpenID Connect client registration for Keycloak.
 *
 * <p>The endpoints are spelled out instead of discovered from
 * {@code issuer-uri} for two reasons:
 * <ul>
 * <li>browser-facing endpoints use the public Keycloak URL, while
 * back-channel endpoints use the in-cluster URL over mTLS;</li>
 * <li>no network call happens at start-up, so the app starts even while
 * Keycloak is still coming up.</li>
 * </ul>
 * The issuer is still set, so the {@code iss} claim of the ID token is validated.
 */
@Configuration(proxyBeanMethods = false)
public class OidcClientConfig {

    /** Registration id; part of the callback URL {@code /login/oauth2/code/keycloak}. */
    public static final String REGISTRATION_ID = "keycloak";

    @Bean
    ClientRegistrationRepository clientRegistrationRepository(PlatformProperties properties) {
        String publicRealm = properties.keycloak().publicRealmUrl();
        String internalRealm = properties.keycloak().internalRealmUrl();

        ClientRegistration registration = ClientRegistration.withRegistrationId(REGISTRATION_ID)
                .clientName("Keycloak (OpenID Connect)")
                .clientId(properties.oidc().clientId())
                // RFC 8705: the TLS client certificate authenticates the client. No client secret exists.
                .clientAuthenticationMethod(ClientAuthenticationMethod.TLS_CLIENT_AUTH)
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                .clientSettings(ClientRegistration.ClientSettings.builder().requireProofKey(true).build())
                .redirectUri(properties.app().publicUrl() + "/login/oauth2/code/{registrationId}")
                .scope(properties.oidc().scopes())
                .issuerUri(publicRealm)
                .authorizationUri(publicRealm + "/protocol/openid-connect/auth")
                .tokenUri(internalRealm + "/protocol/openid-connect/token")
                .jwkSetUri(internalRealm + "/protocol/openid-connect/certs")
                .userInfoUri(internalRealm + "/protocol/openid-connect/userinfo")
                .userNameAttributeName("preferred_username")
                .providerConfigurationMetadata(
                        Map.of("end_session_endpoint", publicRealm + "/protocol/openid-connect/logout"))
                .build();
        return new InMemoryClientRegistrationRepository(registration);
    }

    /**
     * Token endpoint client for {@code tls_client_auth}.
     *
     * <p>Spring Security's default client only accepts the secret-based
     * methods and {@code none}; registering a parameters converter is the
     * documented way to opt in to another method. Nothing has to be added:
     * the default converter already sends {@code client_id}, and the client
     * certificate is presented by the JVM default TLS context (see
     * {@link com.example.platform.app.OutboundTls}).
     */
    @Bean
    OAuth2AccessTokenResponseClient<OAuth2AuthorizationCodeGrantRequest> authorizationCodeTokenResponseClient() {
        RestClientAuthorizationCodeTokenResponseClient client = new RestClientAuthorizationCodeTokenResponseClient();
        client.addParametersConverter(grantRequest -> new LinkedMultiValueMap<String, String>());
        return client;
    }
}
