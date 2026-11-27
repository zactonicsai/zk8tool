package com.example.platform.client;

import static com.example.platform.client.CheckRunner.require;

import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.cert.CertPath;
import java.security.cert.CertPathValidator;
import java.security.cert.CertificateFactory;
import java.security.cert.PKIXParameters;
import java.security.cert.TrustAnchor;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Offline checks of the mounted certificate material: nothing here touches
 * the network, so a failure points at the Secret / cert-manager, not at a peer.
 */
final class CertificateChecks {

    private static final String EKU_CLIENT_AUTH = "1.3.6.1.5.5.7.3.2";
    private static final int KEY_USAGE_DIGITAL_SIGNATURE = 0;

    private final Config config;
    private final TlsMaterial tls;

    CertificateChecks(Config config, TlsMaterial tls) {
        this.config = config;
        this.tls = tls;
    }

    void run(CheckRunner checks) {
        checks.check("CERT-01", "Private key matches the client certificate", this::keyMatchesCertificate);
        checks.check("CERT-02", "Client certificate chains to the configured CA", this::chainsToCa);
        checks.check("CERT-03", "Client certificate is within its validity period",
                () -> validity("client", tls.clientCertificate(), config.minValidity()));
        checks.check("CERT-04", "Client certificate is usable for TLS client authentication", this::clientAuthUsage);
        checks.check("CERT-05", "CA certificates are CA certificates and still valid", this::caCertificates);
    }

    private String keyMatchesCertificate() throws GeneralSecurityException {
        X509Certificate certificate = tls.clientCertificate();
        String keyAlgorithm = certificate.getPublicKey().getAlgorithm();
        String signatureAlgorithm = switch (keyAlgorithm) {
            case "EC" -> "SHA256withECDSA";
            case "RSA" -> "SHA256withRSA";
            case "EdDSA", "Ed25519", "Ed448" -> "EdDSA";
            default -> throw new CheckRunner.CheckFailedException("Unsupported key algorithm " + keyAlgorithm);
        };
        byte[] challenge = new byte[32];
        new SecureRandom().nextBytes(challenge);
        Signature signer = Signature.getInstance(signatureAlgorithm);
        signer.initSign(tls.clientKey());
        signer.update(challenge);
        byte[] signature = signer.sign();
        Signature verifier = Signature.getInstance(signatureAlgorithm);
        verifier.initVerify(certificate.getPublicKey());
        verifier.update(challenge);
        require(verifier.verify(signature), "The private key does not belong to the certificate "
                + certificate.getSubjectX500Principal().getName());
        return certificate.getSubjectX500Principal().getName() + " (" + keyAlgorithm + ")";
    }

    private String chainsToCa() throws GeneralSecurityException {
        Set<TrustAnchor> anchors = tls.trustAnchors().stream()
                .map(ca -> new TrustAnchor(ca, null))
                .collect(Collectors.toSet());
        // A chain file may repeat the root; PKIX wants the path without the anchor.
        List<X509Certificate> path = tls.clientChain().stream()
                .filter(certificate -> !tls.trustAnchors().contains(certificate))
                .toList();
        require(!path.isEmpty(), "The client certificate is itself a trust anchor");
        CertPath certPath = CertificateFactory.getInstance("X.509").generateCertPath(path);
        PKIXParameters parameters = new PKIXParameters(anchors);
        // A private CA without CRL/OCSP endpoints: lifetime is controlled by short validity instead.
        parameters.setRevocationEnabled(false);
        CertPathValidator.getInstance("PKIX").validate(certPath, parameters);
        return "issuer " + tls.clientCertificate().getIssuerX500Principal().getName();
    }

    private String clientAuthUsage() throws GeneralSecurityException {
        X509Certificate certificate = tls.clientCertificate();
        List<String> extendedKeyUsage = certificate.getExtendedKeyUsage();
        require(extendedKeyUsage == null || extendedKeyUsage.contains(EKU_CLIENT_AUTH),
                "extendedKeyUsage " + extendedKeyUsage + " does not include clientAuth (" + EKU_CLIENT_AUTH + ")");
        boolean[] keyUsage = certificate.getKeyUsage();
        require(keyUsage == null || keyUsage[KEY_USAGE_DIGITAL_SIGNATURE],
                "keyUsage does not include digitalSignature");
        require(certificate.getBasicConstraints() == -1, "A CA certificate must not be used as a client certificate");
        return extendedKeyUsage == null ? "no extendedKeyUsage restriction" : "extendedKeyUsage includes clientAuth";
    }

    private String caCertificates() {
        StringBuilder detail = new StringBuilder();
        for (X509Certificate ca : tls.trustAnchors()) {
            String name = ca.getSubjectX500Principal().getName();
            require(ca.getBasicConstraints() >= 0, name + " is not a CA certificate (basicConstraints CA:FALSE)");
            detail.append(detail.isEmpty() ? "" : "; ").append(validity("CA", ca, config.minValidity()));
        }
        return detail.toString();
    }

    /**
     * Fails when the certificate is not yet valid, expired, or expires sooner
     * than {@code minimum}.
     */
    static String validity(String label, X509Certificate certificate, Duration minimum) {
        Instant now = Instant.now();
        Instant notBefore = certificate.getNotBefore().toInstant();
        Instant notAfter = certificate.getNotAfter().toInstant();
        String name = certificate.getSubjectX500Principal().getName();
        require(!now.isBefore(notBefore), label + " certificate " + name + " is not valid before " + notBefore);
        require(now.isBefore(notAfter), label + " certificate " + name + " expired at " + notAfter);
        Duration remaining = Duration.between(now, notAfter);
        require(remaining.compareTo(minimum) >= 0, label + " certificate " + name + " expires in "
                + remaining.toDays() + " days (" + notAfter + "), less than the required " + minimum.toDays());
        return name + " valid for " + remaining.toDays() + " more days";
    }
}
