package com.example.platform.client;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.util.List;

import org.junit.jupiter.api.Test;

class PemAndTlsMaterialTest {

    @Test
    void readsCertificateAndPkcs8Key() throws Exception {
        List<X509Certificate> certificates = Pem.certificates(Fixtures.cert("client.crt"));
        PrivateKey key = Pem.privateKey(Fixtures.cert("client.key"), "EC");

        assertEquals(1, certificates.size());
        assertEquals("CN=test-client,OU=Platform,O=Example Corp,C=US",
                certificates.getFirst().getSubjectX500Principal().getName());
        assertEquals("EC", key.getAlgorithm());
    }

    @Test
    void readsRsaKeys() throws Exception {
        assertEquals("RSA", Pem.privateKey(Fixtures.cert("saml-sp.key"), "RSA").getAlgorithm());
    }

    @Test
    void readsEveryCertificateOfABundle() throws Exception {
        Path bundle = Files.createTempFile("bundle", ".pem");
        try {
            Files.writeString(bundle, Files.readString(Fixtures.cert("ca.crt"))
                    + Files.readString(Fixtures.cert("untrusted-ca.crt")));

            assertEquals(2, Pem.certificates(bundle).size());
        } finally {
            Files.deleteIfExists(bundle);
        }
    }

    @Test
    void explainsHowToConvertSec1Keys() {
        GeneralSecurityException error = assertThrows(GeneralSecurityException.class,
                () -> Pem.privateKey(Fixtures.cert("client-sec1.key"), "EC"));

        assertTrue(error.getMessage().contains("PKCS#8"));
    }

    @Test
    void failsClearlyWhenTheFileHoldsNoCertificateOrKey() {
        assertThrows(GeneralSecurityException.class, () -> Pem.certificates(Fixtures.cert("client.key")));
        assertThrows(GeneralSecurityException.class, () -> Pem.privateKey(Fixtures.cert("client.crt"), "EC"));
    }

    @Test
    void buildsBothTlsContexts() throws Exception {
        TlsMaterial tls = Fixtures.clientTls();

        assertNotNull(tls.mutualTlsContext().getSocketFactory());
        assertNotNull(tls.serverAuthOnlyContext().getSocketFactory());
        assertEquals(1, tls.trustStore().size());
    }

    @Test
    void thumbprintIsUnpaddedBase64UrlSha256() throws Exception {
        String thumbprint = Fixtures.clientTls().clientCertificateThumbprint();

        // 32 bytes -> 43 base64url characters without padding
        assertEquals(43, thumbprint.length());
        assertTrue(thumbprint.matches("[A-Za-z0-9_-]+"));
    }
}
