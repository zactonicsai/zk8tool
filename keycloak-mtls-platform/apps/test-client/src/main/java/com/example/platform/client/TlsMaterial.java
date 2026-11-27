package com.example.platform.client;

import java.io.IOException;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.List;

import javax.net.ssl.KeyManager;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

/**
 * The client's identity (certificate chain + private key) and the CA
 * certificates it trusts. Only these anchors are trusted: the JDK's public
 * root store is deliberately not consulted.
 */
record TlsMaterial(List<X509Certificate> clientChain, PrivateKey clientKey, List<X509Certificate> trustAnchors) {

    private static final char[] NO_PASSWORD = new char[0];

    static TlsMaterial load(Path certificateFile, Path keyFile, Path caFile)
            throws IOException, GeneralSecurityException {
        List<X509Certificate> chain = Pem.certificates(certificateFile);
        PrivateKey key = Pem.privateKey(keyFile, chain.getFirst().getPublicKey().getAlgorithm());
        return new TlsMaterial(chain, key, Pem.certificates(caFile));
    }

    X509Certificate clientCertificate() {
        return clientChain.getFirst();
    }

    /** TLS context that presents the client certificate (mutual TLS). */
    SSLContext mutualTlsContext() throws GeneralSecurityException, IOException {
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        keyStore.load(null, null);
        keyStore.setKeyEntry("client", clientKey, NO_PASSWORD, clientChain.toArray(X509Certificate[]::new));
        KeyManagerFactory keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keyManagers.init(keyStore, NO_PASSWORD);
        return context(keyManagers.getKeyManagers());
    }

    /** TLS context that verifies the server but presents NO client certificate. */
    SSLContext serverAuthOnlyContext() throws GeneralSecurityException, IOException {
        return context(null);
    }

    KeyStore trustStore() throws GeneralSecurityException, IOException {
        KeyStore trustStore = KeyStore.getInstance("PKCS12");
        trustStore.load(null, null);
        for (int i = 0; i < trustAnchors.size(); i++) {
            trustStore.setCertificateEntry("ca-" + i, trustAnchors.get(i));
        }
        return trustStore;
    }

    /** RFC 8705 {@code x5t#S256}: base64url(SHA-256(DER certificate)), no padding. */
    String clientCertificateThumbprint() throws GeneralSecurityException {
        return thumbprint(clientCertificate());
    }

    static String thumbprint(X509Certificate certificate) throws GeneralSecurityException {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded());
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
    }

    private SSLContext context(KeyManager[] keyManagers) throws GeneralSecurityException, IOException {
        TrustManagerFactory trustManagers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        trustManagers.init(trustStore());
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(keyManagers, trustManagers.getTrustManagers(), new SecureRandom());
        return context;
    }
}
