package com.example.platform.app;

import java.io.IOException;
import java.io.InputStream;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;

import org.springframework.core.io.ClassPathResource;

/** Loads the committed certificate fixtures from {@code src/test/resources/certs}. */
public final class TestCertificates {

    /** CN=test-client, issued by the test CA; on the allow-list of the test profile. */
    public static final String CLIENT = "certs/client.crt";

    /** CN=intruder, issued by the same CA but not on the allow-list. */
    public static final String OTHER_CLIENT = "certs/other-client.crt";

    private TestCertificates() {
    }

    public static X509Certificate load(String classpathLocation) {
        try (InputStream in = new ClassPathResource(classpathLocation).getInputStream()) {
            return (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(in);
        } catch (IOException | CertificateException e) {
            throw new IllegalStateException("Cannot load test certificate " + classpathLocation, e);
        }
    }
}
