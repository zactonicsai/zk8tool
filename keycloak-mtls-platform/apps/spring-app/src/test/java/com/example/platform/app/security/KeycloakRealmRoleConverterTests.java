package com.example.platform.app.security;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;

class KeycloakRealmRoleConverterTests {

    private final KeycloakRealmRoleConverter converter = new KeycloakRealmRoleConverter();

    private static Jwt.Builder token() {
        return Jwt.withTokenValue("token").header("alg", "RS256").subject("subject");
    }

    private List<String> authorities(Jwt jwt) {
        return this.converter.convert(jwt).stream().map(GrantedAuthority::getAuthority).toList();
    }

    @Test
    void realmRolesBecomeRoleAuthorities() {
        Jwt jwt = token().claim("realm_access", Map.of("roles", List.of("api-read", "auditor"))).build();

        assertThat(authorities(jwt)).containsExactly("ROLE_api-read", "ROLE_auditor");
    }

    @Test
    void scopesBecomeScopeAuthorities() {
        Jwt jwt = token().claim("scope", "profile  email").build();

        assertThat(authorities(jwt)).containsExactly("SCOPE_profile", "SCOPE_email");
    }

    @Test
    void clientRolesAreIgnored() {
        Jwt jwt = token()
                .claim("resource_access", Map.of("spring-app", Map.of("roles", List.of("admin"))))
                .build();

        assertThat(authorities(jwt)).isEmpty();
    }

    @Test
    void malformedRoleClaimsDoNotBreakConversion() {
        Jwt jwt = token().claim("realm_access", Map.of("roles", List.of("ok", 42, " "))).build();

        assertThat(authorities(jwt)).containsExactly("ROLE_ok");
    }

    @Test
    void tokenWithoutRolesOrScopesHasNoAuthorities() {
        assertThat(authorities(token().build())).isEmpty();
    }
}
