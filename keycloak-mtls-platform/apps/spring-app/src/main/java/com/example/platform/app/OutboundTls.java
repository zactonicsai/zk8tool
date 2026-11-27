package com.example.platform.app;

import java.util.Map;
import java.util.Properties;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ssl.SslBundle;
import org.springframework.boot.ssl.pem.PemSslStoreBundle;
import org.springframework.boot.ssl.pem.PemSslStoreDetails;
import org.springframework.core.io.DefaultResourceLoader;

/**
 * Makes mutual TLS the JVM default for outbound connections.
 *
 * <p>Every HTTPS call this application makes goes to Keycloak: the token
 * endpoint, the JWK Set, the userinfo endpoint and the SAML metadata. Spring
 * Security creates those HTTP clients internally and all of them fall back to
 * the JVM default {@link SSLContext}. Installing one context that
 * <ul>
 * <li>presents this service's certificate (so Keycloak can authenticate the
 * OIDC client with {@code tls_client_auth}), and</li>
 * <li>trusts only the platform CA (not the public roots shipped with the JDK)</li>
 * </ul>
 * therefore covers all of them in one place, with no secret and no per-client
 * wiring. The trade-off: this JVM cannot call public HTTPS endpoints unless
 * their CA is added to the CA bundle.
 *
 * <p>The default context is built once. After a certificate renewal the
 * inbound side reloads by itself ({@code reload-on-update}); outbound calls
 * keep using the old certificate until the pod restarts, so restart the
 * workload on renewal (the Helm chart supports Reloader annotations).
 */
public final class OutboundTls {

    static final String CERTIFICATE = "PLATFORM_TLS_CERTIFICATE";
    static final String PRIVATE_KEY = "PLATFORM_TLS_PRIVATE_KEY";
    static final String CA = "PLATFORM_TLS_CA";

    static final String DEFAULT_CERTIFICATE = "file:/etc/platform/tls/tls.crt";
    static final String DEFAULT_PRIVATE_KEY = "file:/etc/platform/tls/tls.key";
    static final String DEFAULT_CA = "file:/etc/platform/tls/ca.crt";

    private static final Logger log = LoggerFactory.getLogger(OutboundTls.class);

    private OutboundTls() {
    }

    /** Reads the locations from system properties, then environment variables, then the defaults. */
    static boolean installFromEnvironment() {
        return install(System.getenv(), System.getProperties());
    }

    /**
     * @return true when the default context was replaced, false when the
     *         certificate material is absent (local development without TLS)
     */
    static boolean install(Map<String, String> environment, Properties systemProperties) {
        String certificate = resolve(CERTIFICATE, DEFAULT_CERTIFICATE, environment, systemProperties);
        String privateKey = resolve(PRIVATE_KEY, DEFAULT_PRIVATE_KEY, environment, systemProperties);
        String ca = resolve(CA, DEFAULT_CA, environment, systemProperties);

        DefaultResourceLoader resources = new DefaultResourceLoader();
        if (!resources.getResource(certificate).exists() || !resources.getResource(ca).exists()) {
            log.warn("Outbound mTLS is NOT configured: {} or {} does not exist. "
                    + "Calls to Keycloak will use the JVM default trust store and no client certificate.",
                    certificate, ca);
            return false;
        }
        SSLContext context = createContext(certificate, privateKey, ca);
        SSLContext.setDefault(context);
        HttpsURLConnection.setDefaultSSLSocketFactory(context.getSocketFactory());
        log.info("Outbound mTLS configured: client certificate {}, trusted CA bundle {}", certificate, ca);
        return true;
    }

    /** Builds a TLS context from PEM locations (file:, classpath: or inline PEM text). */
    static SSLContext createContext(String certificate, String privateKey, String ca) {
        PemSslStoreDetails keyStore = PemSslStoreDetails.forCertificate(certificate).withPrivateKey(privateKey);
        PemSslStoreDetails trustStore = PemSslStoreDetails.forCertificate(ca);
        return SslBundle.of(new PemSslStoreBundle(keyStore, trustStore)).createSslContext();
    }

    private static String resolve(String name, String fallback, Map<String, String> environment,
            Properties systemProperties) {
        String value = systemProperties.getProperty(name);
        if (value == null || value.isBlank()) {
            value = environment.get(name);
        }
        return (value == null || value.isBlank()) ? fallback : value.strip();
    }
}
