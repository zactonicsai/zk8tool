package com.example.platform.app.security;

import java.security.cert.X509Certificate;
import java.util.List;
import java.util.function.Supplier;

import javax.security.auth.x500.X500Principal;

import jakarta.servlet.http.HttpServletRequest;

import org.springframework.security.authorization.AuthorizationDecision;
import org.springframework.security.authorization.AuthorizationManager;
import org.springframework.security.authorization.AuthorizationResult;
import org.springframework.security.core.Authentication;
import org.springframework.security.web.access.intercept.RequestAuthorizationContext;

/**
 * Grants access only when the request arrived over mutual TLS.
 *
 * <p>The TLS layer already validated the client certificate against the
 * trusted CA (a certificate that fails validation aborts the handshake), so
 * its presence means "issued by our CA and not expired". Optionally the
 * subject must also be on an allow-list.
 *
 * <p>This is what lets the server run with {@code client-auth: want}: browser
 * users reach the login pages without a certificate, while {@code /api/**}
 * combines this manager with a role check and so requires certificate AND token.
 */
public final class ClientCertificateAuthorizationManager implements AuthorizationManager<RequestAuthorizationContext> {

    /** Servlet-spec request attribute holding the client certificate chain. */
    public static final String CERTIFICATE_ATTRIBUTE = "jakarta.servlet.request.X509Certificate";

    private final List<X500Principal> allowedSubjects;

    /** @param allowedSubjects subjects that may connect; empty allows any trusted certificate */
    public ClientCertificateAuthorizationManager(List<X500Principal> allowedSubjects) {
        this.allowedSubjects = List.copyOf(allowedSubjects);
    }

    @Override
    public AuthorizationResult authorize(Supplier<? extends Authentication> authentication,
            RequestAuthorizationContext context) {
        X509Certificate certificate = clientCertificate(context.getRequest());
        if (certificate == null) {
            return new AuthorizationDecision(false);
        }
        // X500Principal.equals compares canonical forms, so spacing and
        // attribute-type case in the configured DN do not matter.
        boolean allowed = this.allowedSubjects.isEmpty()
                || this.allowedSubjects.contains(certificate.getSubjectX500Principal());
        return new AuthorizationDecision(allowed);
    }

    /** The leaf certificate the client presented, or null when it presented none. */
    public static X509Certificate clientCertificate(HttpServletRequest request) {
        return request.getAttribute(CERTIFICATE_ATTRIBUTE) instanceof X509Certificate[] chain && chain.length > 0
                ? chain[0]
                : null;
    }
}
