package com.example.platform.app;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Java 25 Spring Boot application that authenticates users against Keycloak
 * with OpenID Connect and SAML 2.0 and exposes an API that requires mutual
 * TLS plus a JWT access token.
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class PlatformApplication {

    public static void main(String[] args) {
        // Must happen before the application context starts: Spring Security
        // fetches the SAML IdP metadata while the context is still being built.
        OutboundTls.installFromEnvironment();
        SpringApplication.run(PlatformApplication.class, args);
    }
}
