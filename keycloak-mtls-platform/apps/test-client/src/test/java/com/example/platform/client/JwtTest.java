package com.example.platform.client;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.security.GeneralSecurityException;
import java.time.Instant;
import java.util.List;

import org.junit.jupiter.api.Test;

class JwtTest {

    private static final String CLAIMS = """
            {"iss":"https://sso/realms/platform","aud":"spring-app","azp":"test-client","exp":4102444800,
             "cnf":{"x5t#S256":"thumb"},"realm_access":{"roles":["api-read","other"]}}
            """;

    @Test
    void exposesTheClaimsTheChecksNeed() throws Exception {
        Jwt jwt = Jwt.parse(TestTokens.rsa("k1").sign(CLAIMS));

        assertEquals("RS256", jwt.algorithm());
        assertEquals("k1", jwt.keyId());
        assertEquals("https://sso/realms/platform", jwt.issuer());
        assertEquals("test-client", jwt.authorizedParty());
        assertEquals(List.of("spring-app"), jwt.audience());
        assertEquals(Instant.ofEpochSecond(4102444800L), jwt.expiresAt());
        assertEquals("thumb", jwt.certificateThumbprint());
        assertEquals(List.of("api-read", "other"), jwt.realmRoles());
    }

    @Test
    void missingOptionalClaimsYieldNullOrEmpty() throws Exception {
        Jwt jwt = Jwt.parse(TestTokens.rsa("k1").sign("{\"iss\":\"x\"}"));

        assertNull(jwt.certificateThumbprint());
        assertNull(jwt.expiresAt());
        assertEquals(List.of(), jwt.audience());
        assertEquals(List.of(), jwt.realmRoles());
    }

    @Test
    void verifiesRsaSignatures() throws Exception {
        TestTokens tokens = TestTokens.rsa("k1");

        assertTrue(Jwt.parse(tokens.sign(CLAIMS)).verifySignature(tokens.jwks()));
    }

    @Test
    void verifiesEcSignatures() throws Exception {
        TestTokens tokens = TestTokens.ec("ec1");

        assertTrue(Jwt.parse(tokens.sign(CLAIMS)).verifySignature(tokens.jwks()));
    }

    @Test
    void rejectsTokenSignedByAnotherKeyWithTheSameKeyId() throws Exception {
        String forged = TestTokens.rsa("k1").sign(CLAIMS);

        assertFalse(Jwt.parse(forged).verifySignature(TestTokens.rsa("k1").jwks()));
    }

    @Test
    void rejectsTokenWhoseKeyIsNotInTheSet() throws Exception {
        String token = TestTokens.rsa("unknown").sign(CLAIMS);

        assertFalse(Jwt.parse(token).verifySignature(TestTokens.rsa("k1").jwks()));
    }

    @Test
    void rejectsModifiedClaims() throws Exception {
        TestTokens tokens = TestTokens.rsa("k1");
        String[] parts = tokens.sign(CLAIMS).split("\\.");
        String tampered = parts[0] + "." + TestTokens.encode(CLAIMS.replace("api-read", "admin")) + "." + parts[2];

        assertFalse(Jwt.parse(tampered).verifySignature(tokens.jwks()));
    }

    @Test
    void refusesUnsignedAndSymmetricAlgorithms() throws Exception {
        TestTokens tokens = TestTokens.rsa("k1");
        for (String algorithm : List.of("none", "HS256")) {
            String token = TestTokens.encode("{\"alg\":\"" + algorithm + "\",\"kid\":\"k1\"}") + "."
                    + TestTokens.encode(CLAIMS) + ".c2ln";

            assertThrows(GeneralSecurityException.class, () -> Jwt.parse(token).verifySignature(tokens.jwks()));
        }
    }

    @Test
    void rejectsStringsThatAreNotCompactJws() {
        assertThrows(IllegalArgumentException.class, () -> Jwt.parse("not-a-jwt"));
        assertThrows(IllegalArgumentException.class, () -> Jwt.parse("a.b"));
        assertThrows(IllegalArgumentException.class, () -> Jwt.parse("!!!.e30.c2ln"));
    }
}
