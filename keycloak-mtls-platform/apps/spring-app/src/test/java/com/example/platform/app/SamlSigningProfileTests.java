package com.example.platform.app;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

/**
 * With the {@code saml-signing} profile (the deployment default) the
 * AuthnRequest must be signed with the SP key, because the Keycloak client is
 * configured with "Client signature required".
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles({"test", "saml-signing"})
class SamlSigningProfileTests {

    private static final Pattern SAML_REQUEST = Pattern.compile("name=\"SAMLRequest\"[^>]*value=\"([^\"]+)\"");

    @Autowired
    private MockMvc mvc;

    @Test
    void authnRequestIsSigned() throws Exception {
        MockHttpServletResponse response = mvc.perform(get("/saml2/authenticate/keycloak")).andReturn().getResponse();

        if (response.getStatus() == 302) {
            // Redirect binding: the signature travels as query parameters.
            assertThat(response.getHeader("Location")).contains("SAMLRequest=").contains("Signature=");
            return;
        }
        // POST binding: the signature is embedded in the base64-encoded XML.
        assertThat(response.getStatus()).isEqualTo(200);
        Matcher matcher = SAML_REQUEST.matcher(response.getContentAsString());
        assertThat(matcher.find()).as("SAMLRequest form field").isTrue();
        String xml = new String(Base64.getMimeDecoder().decode(matcher.group(1)), StandardCharsets.UTF_8);
        assertThat(xml).contains("AuthnRequest").contains("SignatureValue");
    }

    @Test
    void metadataAdvertisesTheSigningCertificate() throws Exception {
        String metadata = mvc.perform(get("/saml2/metadata/keycloak")).andReturn().getResponse().getContentAsString();

        assertThat(metadata).contains("KeyDescriptor").contains("X509Certificate");
    }
}
