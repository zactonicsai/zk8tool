package com.example.platform.client;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.util.Base64;
import java.util.Map;
import java.util.StringJoiner;

/** Test helper that signs JWTs and publishes the matching JWK, like an authorization server would. */
final class TestTokens {

    private static final Base64.Encoder URL = Base64.getUrlEncoder().withoutPadding();

    private final KeyPair keyPair;
    private final String algorithm;
    private final String keyId;

    private TestTokens(KeyPair keyPair, String algorithm, String keyId) {
        this.keyPair = keyPair;
        this.algorithm = algorithm;
        this.keyId = keyId;
    }

    static TestTokens rsa(String keyId) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        return new TestTokens(generator.generateKeyPair(), "RS256", keyId);
    }

    static TestTokens ec(String keyId) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        return new TestTokens(generator.generateKeyPair(), "ES256", keyId);
    }

    /** Signs {@code claimsJson} (a JSON object as text) and returns the compact JWS. */
    String sign(String claimsJson) throws Exception {
        String header = "{\"alg\":\"" + algorithm + "\",\"typ\":\"JWT\",\"kid\":\"" + keyId + "\"}";
        String signingInput = encode(header) + "." + encode(claimsJson);
        Signature signer = Signature.getInstance(
                algorithm.equals("RS256") ? "SHA256withRSA" : "SHA256withECDSAinP1363Format");
        signer.initSign(keyPair.getPrivate());
        signer.update(signingInput.getBytes(StandardCharsets.US_ASCII));
        return signingInput + "." + URL.encodeToString(signer.sign());
    }

    /** The JWK Set document containing this key. */
    String jwksJson() {
        StringJoiner members = new StringJoiner(",", "{", "}");
        members.add("\"kid\":\"" + keyId + "\"").add("\"use\":\"sig\"").add("\"alg\":\"" + algorithm + "\"");
        if (keyPair.getPublic() instanceof RSAPublicKey rsa) {
            members.add("\"kty\":\"RSA\"")
                    .add("\"n\":\"" + unsigned(rsa.getModulus()) + "\"")
                    .add("\"e\":\"" + unsigned(rsa.getPublicExponent()) + "\"");
        } else if (keyPair.getPublic() instanceof ECPublicKey ec) {
            members.add("\"kty\":\"EC\"").add("\"crv\":\"P-256\"")
                    .add("\"x\":\"" + unsigned(ec.getW().getAffineX()) + "\"")
                    .add("\"y\":\"" + unsigned(ec.getW().getAffineY()) + "\"");
        }
        return "{\"keys\":[" + members + "]}";
    }

    Map<String, Object> jwks() {
        return Json.parseObject(jwksJson());
    }

    static String encode(String text) {
        return URL.encodeToString(text.getBytes(StandardCharsets.UTF_8));
    }

    private static String unsigned(BigInteger value) {
        byte[] bytes = value.toByteArray();
        if (bytes.length > 1 && bytes[0] == 0) {
            bytes = java.util.Arrays.copyOfRange(bytes, 1, bytes.length);
        }
        return URL.encodeToString(bytes);
    }
}
