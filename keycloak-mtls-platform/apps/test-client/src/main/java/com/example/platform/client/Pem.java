package com.example.platform.client;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Minimal PEM reader for the two things this client needs: X.509 certificates
 * and unencrypted PKCS#8 private keys. Uses only the JDK.
 */
final class Pem {

    /** One {@code -----BEGIN x-----} block. */
    record Block(String type, byte[] der) {
    }

    private static final Pattern BLOCK = Pattern.compile(
            "-----BEGIN ([A-Z0-9 ]+)-----(.*?)-----END \\1-----", Pattern.DOTALL);

    private Pem() {
    }

    static List<Block> parse(String text) {
        List<Block> blocks = new ArrayList<>();
        Matcher matcher = BLOCK.matcher(text);
        while (matcher.find()) {
            byte[] der = Base64.getMimeDecoder().decode(matcher.group(2).strip());
            blocks.add(new Block(matcher.group(1), der));
        }
        return blocks;
    }

    /** Reads every certificate in the file, in file order (leaf first for a chain). */
    static List<X509Certificate> certificates(Path file) throws IOException, GeneralSecurityException {
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        List<X509Certificate> certificates = new ArrayList<>();
        for (Block block : parse(Files.readString(file, StandardCharsets.US_ASCII))) {
            if (block.type().equals("CERTIFICATE")) {
                certificates.add((X509Certificate) factory
                        .generateCertificate(new ByteArrayInputStream(block.der())));
            }
        }
        if (certificates.isEmpty()) {
            throw new GeneralSecurityException("No CERTIFICATE block found in " + file);
        }
        return List.copyOf(certificates);
    }

    /**
     * Reads an unencrypted PKCS#8 key ({@code BEGIN PRIVATE KEY}).
     *
     * @param algorithm key algorithm of the matching certificate, e.g. {@code EC} or {@code RSA}
     */
    static PrivateKey privateKey(Path file, String algorithm) throws IOException, GeneralSecurityException {
        for (Block block : parse(Files.readString(file, StandardCharsets.US_ASCII))) {
            switch (block.type()) {
                case "PRIVATE KEY" -> {
                    return KeyFactory.getInstance(algorithm).generatePrivate(new PKCS8EncodedKeySpec(block.der()));
                }
                case "EC PRIVATE KEY", "RSA PRIVATE KEY" -> throw new GeneralSecurityException(
                        file + " is a " + block.type() + " (SEC1/PKCS#1). Convert it to PKCS#8 with "
                                + "'openssl pkcs8 -topk8 -nocrypt', or set privateKey.encoding: PKCS8 in cert-manager.");
                case "ENCRYPTED PRIVATE KEY" -> throw new GeneralSecurityException(
                        file + " is password protected; an unencrypted PKCS#8 key is required.");
                default -> {
                    // other block types (certificates, parameters) are ignored
                }
            }
        }
        throw new GeneralSecurityException("No PRIVATE KEY block found in " + file);
    }
}
