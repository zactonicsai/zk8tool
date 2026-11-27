package com.example.platform.app.security;

import static org.assertj.core.api.Assertions.assertThat;

import java.security.cert.X509Certificate;
import java.util.List;

import javax.security.auth.x500.X500Principal;

import com.example.platform.app.TestCertificates;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.web.access.intercept.RequestAuthorizationContext;

class ClientCertificateAuthorizationManagerTests {

    private static final X509Certificate CLIENT = TestCertificates.load(TestCertificates.CLIENT);
    private static final X509Certificate OTHER = TestCertificates.load(TestCertificates.OTHER_CLIENT);

    private static boolean granted(ClientCertificateAuthorizationManager manager, X509Certificate... chain) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        if (chain.length > 0) {
            request.setAttribute(ClientCertificateAuthorizationManager.CERTIFICATE_ATTRIBUTE, chain);
        }
        return manager.authorize(() -> null, new RequestAuthorizationContext(request)).isGranted();
    }

    @Test
    void deniesWhenNoClientCertificateWasPresented() {
        assertThat(granted(new ClientCertificateAuthorizationManager(List.of()))).isFalse();
    }

    @Test
    void anyTrustedCertificateIsAllowedWhenTheAllowListIsEmpty() {
        ClientCertificateAuthorizationManager manager = new ClientCertificateAuthorizationManager(List.of());

        assertThat(granted(manager, CLIENT)).isTrue();
        assertThat(granted(manager, OTHER)).isTrue();
    }

    @Test
    void onlyListedSubjectsAreAllowed() {
        ClientCertificateAuthorizationManager manager = new ClientCertificateAuthorizationManager(
                List.of(new X500Principal("CN=test-client,OU=Platform,O=Example Corp,C=US")));

        assertThat(granted(manager, CLIENT)).isTrue();
        assertThat(granted(manager, OTHER)).isFalse();
    }

    @Test
    void subjectComparisonIgnoresSpacingAndCase() {
        ClientCertificateAuthorizationManager manager = new ClientCertificateAuthorizationManager(
                List.of(new X500Principal("cn=TEST-CLIENT, ou=Platform, o=Example Corp, c=US")));

        assertThat(granted(manager, CLIENT)).isTrue();
    }

    @Test
    void theLeafCertificateIsTheFirstInTheChain() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setAttribute(ClientCertificateAuthorizationManager.CERTIFICATE_ATTRIBUTE,
                new X509Certificate[] {OTHER, CLIENT});

        assertThat(ClientCertificateAuthorizationManager.clientCertificate(request)).isSameAs(OTHER);
        assertThat(ClientCertificateAuthorizationManager.clientCertificate(new MockHttpServletRequest())).isNull();
    }
}
