package com.example.platform.client;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.security.spec.RSAPublicKeySpec;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * A parsed JWS compact token plus signature verification against a JWK Set
 * (RS256/384/512 and ES256/384). Enough to prove a Keycloak access token is
 * genuine without pulling in a JOSE library.
 */
record Jwt(Map<String, Object> header, Map<String, Object> claims, byte[] signingInput, byte[] signature) {

    private static final Base64.Decoder URL = Base64.getUrlDecoder();

    static Jwt parse(String compact) {
        String[] parts = compact.split("\\.", -1);
        if (parts.length != 3) {
            throw new IllegalArgumentException("Not a signed JWT: expected 3 parts but found " + parts.length);
        }
        Map<String, Object> header = Json.parseObject(new String(URL.decode(parts[0]), StandardCharsets.UTF_8));
        Map<String, Object> claims = Json.parseObject(new String(URL.decode(parts[1]), StandardCharsets.UTF_8));
        byte[] signingInput = (parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII);
        return new Jwt(header, claims, signingInput, URL.decode(parts[2]));
    }

    String algorithm() {
        return Json.string(header, "alg");
    }

    String keyId() {
        return Json.string(header, "kid");
    }

    String issuer() {
        return Json.string(claims, "iss");
    }

    String authorizedParty() {
        return Json.string(claims, "azp");
    }

    List<String> audience() {
        return Json.stringList(claims.get("aud"));
    }

    Instant expiresAt() {
        return claims.get("exp") instanceof Number seconds ? Instant.ofEpochSecond(seconds.longValue()) : null;
    }

    /** RFC 8705 confirmation claim {@code cnf.x5t#S256}, or null when the token is not certificate-bound. */
    String certificateThumbprint() {
        return claims.get("cnf") instanceof Map<?, ?> cnf && cnf.get("x5t#S256") instanceof String value ? value : null;
    }

    /** Keycloak realm roles ({@code realm_access.roles}). */
    List<String> realmRoles() {
        return claims.get("realm_access") instanceof Map<?, ?> access ? Json.stringList(access.get("roles")) : List.of();
    }

    /**
     * Verifies the signature with the key from {@code jwks} whose {@code kid}
     * matches the token header.
     *
     * @param jwks the parsed JWK Set document ({@code {"keys": [...]}})
     * @return true only when a matching key exists and the signature is valid
     */
    boolean verifySignature(Map<String, Object> jwks) throws GeneralSecurityException {
        String jcaAlgorithm = switch (Objects.requireNonNullElse(algorithm(), "")) {
            case "RS256" -> "SHA256withRSA";
            case "RS384" -> "SHA384withRSA";
            case "RS512" -> "SHA512withRSA";
            case "ES256" -> "SHA256withECDSAinP1363Format";
            case "ES384" -> "SHA384withECDSAinP1363Format";
            // "none" and symmetric algorithms are never acceptable for an access token.
            default -> throw new GeneralSecurityException("Unsupported or unsafe JWT algorithm: " + algorithm());
        };
        for (Object entry : Json.asArray(jwks.getOrDefault("keys", List.of()))) {
            Map<String, Object> jwk = Json.asObject(entry);
            if (!Objects.equals(Json.string(jwk, "kid"), keyId())) {
                continue;
            }
            Signature verifier = Signature.getInstance(jcaAlgorithm);
            verifier.initVerify(publicKey(jwk));
            verifier.update(signingInput);
            return verifier.verify(signature);
        }
        return false;
    }

    static PublicKey publicKey(Map<String, Object> jwk) throws GeneralSecurityException {
        String type = Json.string(jwk, "kty");
        return switch (Objects.requireNonNullElse(type, "")) {
            case "RSA" -> KeyFactory.getInstance("RSA").generatePublic(
                    new RSAPublicKeySpec(unsigned(jwk, "n"), unsigned(jwk, "e")));
            case "EC" -> {
                String curve = switch (Objects.requireNonNullElse(Json.string(jwk, "crv"), "")) {
                    case "P-256" -> "secp256r1";
                    case "P-384" -> "secp384r1";
                    case "P-521" -> "secp521r1";
                    default -> throw new GeneralSecurityException("Unsupported curve: " + jwk.get("crv"));
                };
                AlgorithmParameters parameters = AlgorithmParameters.getInstance("EC");
                parameters.init(new ECGenParameterSpec(curve));
                ECPoint point = new ECPoint(unsigned(jwk, "x"), unsigned(jwk, "y"));
                yield KeyFactory.getInstance("EC").generatePublic(
                        new ECPublicKeySpec(point, parameters.getParameterSpec(ECParameterSpec.class)));
            }
            default -> throw new GeneralSecurityException("Unsupported key type: " + type);
        };
    }

    private static BigInteger unsigned(Map<String, Object> jwk, String member) throws GeneralSecurityException {
        String value = Json.string(jwk, member);
        if (value == null) {
            throw new GeneralSecurityException("JWK is missing '" + member + "'");
        }
        return new BigInteger(1, URL.decode(value));
    }
}
