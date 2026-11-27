package com.example.platform.app.security;

import com.example.platform.app.config.PlatformProperties;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.security.authorization.AuthorityAuthorizationManager;
import org.springframework.security.authorization.AuthorizationManager;
import org.springframework.security.authorization.AuthorizationManagers;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.client.endpoint.OAuth2AccessTokenResponseClient;
import org.springframework.security.oauth2.client.endpoint.OAuth2AuthorizationCodeGrantRequest;
import org.springframework.security.oauth2.client.oidc.web.logout.OidcClientInitiatedLogoutSuccessHandler;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.access.intercept.RequestAuthorizationContext;

/**
 * Two filter chains:
 * <ol>
 * <li>{@code /api/**} - stateless. Needs a client certificate (mutual TLS)
 * AND a Keycloak JWT with the required realm role. Tokens that Keycloak bound
 * to a certificate ({@code cnf.x5t#S256}) are additionally checked against the
 * presented certificate by Spring Security's default JWT validators.</li>
 * <li>everything else - browser sessions. Users sign in with OpenID Connect
 * or SAML 2.0, both against the same Keycloak realm.</li>
 * </ol>
 */
@Configuration(proxyBeanMethods = false)
@EnableWebSecurity
public class SecurityConfig {

    /** Custom chooser page listing both sign-in options; see {@code LoginController}. */
    public static final String LOGIN_PAGE = "/login";

    @Bean
    @Order(1)
    SecurityFilterChain apiSecurityFilterChain(HttpSecurity http, PlatformProperties properties) throws Exception {
        AuthorizationManager<RequestAuthorizationContext> certificateAndRole = AuthorizationManagers.allOf(
                AuthorityAuthorizationManager.<RequestAuthorizationContext>hasRole(properties.api().requiredRole()),
                new ClientCertificateAuthorizationManager(properties.api().allowedClientPrincipals()));

        JwtAuthenticationConverter jwtConverter = new JwtAuthenticationConverter();
        jwtConverter.setJwtGrantedAuthoritiesConverter(new KeycloakRealmRoleConverter());

        http.securityMatcher("/api/**")
                .authorizeHttpRequests(authorize -> authorize.anyRequest().access(certificateAndRole))
                .oauth2ResourceServer(resourceServer -> resourceServer
                        .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtConverter)))
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                // No cookies, no session: nothing for CSRF to ride on.
                .csrf(AbstractHttpConfigurer::disable)
                .requestCache(AbstractHttpConfigurer::disable);
        return http.build();
    }

    @Bean
    @Order(2)
    SecurityFilterChain webSecurityFilterChain(HttpSecurity http, ClientRegistrationRepository clientRegistrations,
            OAuth2AccessTokenResponseClient<OAuth2AuthorizationCodeGrantRequest> tokenResponseClient)
            throws Exception {
        OidcClientInitiatedLogoutSuccessHandler logoutSuccessHandler = new OidcClientInitiatedLogoutSuccessHandler(
                clientRegistrations);
        // Must be allowed by the client's "post.logout.redirect.uris" in Keycloak.
        logoutSuccessHandler.setPostLogoutRedirectUri("{baseUrl}/");

        http.authorizeHttpRequests(authorize -> authorize
                .requestMatchers("/", LOGIN_PAGE, "/error", "/favicon.ico").permitAll()
                // Health and info only; everything else under /actuator stays closed.
                .requestMatchers("/actuator/health/**", "/actuator/health", "/actuator/info").permitAll()
                .requestMatchers("/actuator/**").denyAll()
                .anyRequest().authenticated())
                // A shared, explicit login page keeps the entry point predictable
                // when two login mechanisms are active.
                .oauth2Login(oauth2 -> oauth2
                        .loginPage(LOGIN_PAGE)
                        .tokenEndpoint(token -> token.accessTokenResponseClient(tokenResponseClient)))
                .saml2Login(saml2 -> saml2.loginPage(LOGIN_PAGE))
                // Publishes SP metadata at /saml2/metadata/{registrationId}.
                .saml2Metadata(Customizer.withDefaults())
                .logout(logout -> logout.logoutSuccessHandler(logoutSuccessHandler));
        return http.build();
    }
}
