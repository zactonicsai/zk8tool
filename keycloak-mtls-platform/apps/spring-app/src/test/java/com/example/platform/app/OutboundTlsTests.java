package com.example.platform.app;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.security.NoSuchAlgorithmException;
import java.util.Map;
import java.util.Properties;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class OutboundTlsTests {

    private static final Map<String, String> FIXTURES = Map.of(
            OutboundTls.CERTIFICATE, "classpath:certs/client.crt",
            OutboundTls.PRIVATE_KEY, "classpath:certs/client.key",
            OutboundTls.CA, "classpath:certs/ca.crt");

    private SSLContext originalContext;
    private SSLSocketFactory originalSocketFactory;

    @BeforeEach
    void rememberJvmDefaults() throws NoSuchAlgorithmException {
        this.originalContext = SSLContext.getDefault();
        this.originalSocketFactory = HttpsURLConnection.getDefaultSSLSocketFactory();
    }

    @AfterEach
    void restoreJvmDefaults() {
        SSLContext.setDefault(this.originalContext);
        HttpsURLConnection.setDefaultSSLSocketFactory(this.originalSocketFactory);
    }

    @Test
    void installsDefaultContextFromPemFiles() throws NoSuchAlgorithmException {
        boolean installed = OutboundTls.install(FIXTURES, new Properties());

        assertThat(installed).isTrue();
        assertThat(SSLContext.getDefault()).isNotSameAs(this.originalContext);
        assertThat(HttpsURLConnection.getDefaultSSLSocketFactory()).isNotSameAs(this.originalSocketFactory);
    }

    @Test
    void systemPropertiesWinOverEnvironmentVariables() throws NoSuchAlgorithmException {
        Properties systemProperties = new Properties();
        systemProperties.setProperty(OutboundTls.CERTIFICATE, "classpath:certs/does-not-exist.crt");

        boolean installed = OutboundTls.install(FIXTURES, systemProperties);

        assertThat(installed).isFalse();
        assertThat(SSLContext.getDefault()).isSameAs(this.originalContext);
    }

    @Test
    void leavesJvmDefaultsAloneWhenNoCertificateMaterialExists() throws NoSuchAlgorithmException {
        Map<String, String> missing = Map.of(
                OutboundTls.CERTIFICATE, "file:/nonexistent/tls.crt",
                OutboundTls.PRIVATE_KEY, "file:/nonexistent/tls.key",
                OutboundTls.CA, "file:/nonexistent/ca.crt");

        assertThat(OutboundTls.install(missing, new Properties())).isFalse();
        assertThat(SSLContext.getDefault()).isSameAs(this.originalContext);
    }

    @Test
    void contextIsCreatedFromCertificateKeyAndCa() {
        SSLContext context = OutboundTls.createContext(
                "classpath:certs/client.crt", "classpath:certs/client.key", "classpath:certs/ca.crt");

        assertThat(context.getProtocol()).isEqualTo("TLS");
        assertThat(context.getSocketFactory()).isNotNull();
    }

    @Test
    void missingPrivateKeyIsReported() {
        assertThatThrownBy(() -> OutboundTls.createContext(
                "classpath:certs/client.crt", "classpath:certs/does-not-exist.key", "classpath:certs/ca.crt"))
                .isInstanceOf(RuntimeException.class);
    }
}
