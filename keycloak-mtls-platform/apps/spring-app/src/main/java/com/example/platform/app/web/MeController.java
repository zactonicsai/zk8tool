package com.example.platform.app.web;

import java.util.List;

import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.saml2.provider.service.authentication.Saml2Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Shows the signed-in browser user and which protocol authenticated them. */
@RestController
public class MeController {

    /**
     * @param name        user name ({@code preferred_username} for OIDC, NameID for SAML)
     * @param protocol    {@code oidc} or {@code saml2}
     * @param authorities granted authorities
     */
    public record Me(String name, String protocol, List<String> authorities) {
    }

    @GetMapping("/me")
    Me me(Authentication authentication) {
        String protocol = switch (authentication) {
            case OAuth2AuthenticationToken _ -> "oidc";
            case Saml2Authentication _ -> "saml2";
            default -> authentication.getClass().getSimpleName();
        };
        List<String> authorities = authentication.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .sorted()
                .toList();
        return new Me(authentication.getName(), protocol, authorities);
    }
}
