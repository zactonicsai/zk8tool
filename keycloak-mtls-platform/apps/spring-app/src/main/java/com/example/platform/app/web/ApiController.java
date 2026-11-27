package com.example.platform.app.web;

import java.security.cert.X509Certificate;
import java.util.List;
import java.util.Map;

import com.example.platform.app.security.ClientCertificateAuthorizationManager;

import jakarta.servlet.http.HttpServletRequest;

import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Machine-to-machine API. Reaching a method here means the caller presented a
 * trusted client certificate and a valid Keycloak access token with the
 * required role (enforced in {@code SecurityConfig}).
 */
@RestController
@RequestMapping("/api/v1")
public class ApiController {

    private static final String ROLE_PREFIX = "ROLE_";

    /**
     * @param subject            {@code sub} claim of the access token
     * @param clientId           {@code azp} claim: the OAuth client the token was issued to
     * @param roles              realm roles carried by the token
     * @param certificateSubject subject DN of the TLS client certificate
     * @param certificateBound   whether the token is bound to a certificate ({@code cnf.x5t#S256})
     */
    public record WhoAmI(String subject, String clientId, List<String> roles, String certificateSubject,
            boolean certificateBound) {
    }

    @GetMapping("/whoami")
    WhoAmI whoAmI(JwtAuthenticationToken authentication, HttpServletRequest request) {
        Jwt jwt = authentication.getToken();
        X509Certificate certificate = ClientCertificateAuthorizationManager.clientCertificate(request);
        List<String> roles = authentication.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .filter(authority -> authority.startsWith(ROLE_PREFIX))
                .map(authority -> authority.substring(ROLE_PREFIX.length()))
                .sorted()
                .toList();
        Map<String, Object> confirmation = jwt.getClaimAsMap("cnf");
        return new WhoAmI(
                jwt.getSubject(),
                jwt.getClaimAsString("azp"),
                roles,
                certificate == null ? null : certificate.getSubjectX500Principal().getName(),
                confirmation != null && confirmation.containsKey("x5t#S256"));
    }
}
