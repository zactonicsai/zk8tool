package com.example.platform.app.security;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

import org.springframework.core.convert.converter.Converter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;

/**
 * Maps a Keycloak access token to Spring Security authorities:
 * <ul>
 * <li>each realm role in {@code realm_access.roles} becomes {@code ROLE_<role>}</li>
 * <li>each entry of the space-separated {@code scope} claim becomes {@code SCOPE_<scope>}</li>
 * </ul>
 * Client roles ({@code resource_access}) are intentionally ignored: this API
 * authorises on realm roles only.
 */
public final class KeycloakRealmRoleConverter implements Converter<Jwt, Collection<GrantedAuthority>> {

    @Override
    public Collection<GrantedAuthority> convert(Jwt jwt) {
        List<GrantedAuthority> authorities = new ArrayList<>();
        Map<String, Object> realmAccess = jwt.getClaimAsMap("realm_access");
        if (realmAccess != null && realmAccess.get("roles") instanceof Collection<?> roles) {
            for (Object role : roles) {
                if (role instanceof String name && !name.isBlank()) {
                    authorities.add(new SimpleGrantedAuthority("ROLE_" + name));
                }
            }
        }
        String scope = jwt.getClaimAsString("scope");
        if (scope != null) {
            for (String item : scope.split(" ")) {
                if (!item.isBlank()) {
                    authorities.add(new SimpleGrantedAuthority("SCOPE_" + item));
                }
            }
        }
        return authorities;
    }
}
