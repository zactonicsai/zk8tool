package com.example.platform.client;

import java.io.PrintStream;
import java.net.URI;
import java.time.Duration;
import java.util.Map;

/**
 * Entry point of the connectivity and certificate test client.
 *
 * <p>Exit codes: {@code 0} every check passed (or was skipped), {@code 1} at
 * least one check failed, {@code 2} invalid configuration or unreadable
 * certificate material.
 */
public final class TestClient {

    static final int EXIT_OK = 0;
    static final int EXIT_CHECKS_FAILED = 1;
    static final int EXIT_CONFIG_ERROR = 2;

    private TestClient() {
    }

    public static void main(String[] args) {
        System.exit(execute(args, System.getenv(), System.out));
    }

    /** Dispatches on the command line: no argument runs the checks, {@code --wait-only} only waits. */
    static int execute(String[] args, Map<String, String> environment, PrintStream out) {
        if (args.length == 0) {
            return run(environment, out);
        }
        if (args.length == 1 && args[0].equals("--wait-only")) {
            return waitForKeycloak(environment, out);
        }
        out.println("Usage: java -jar test-client.jar [--wait-only]");
        out.println("  (no argument)  run the configured checks and print a report");
        out.println("  --wait-only    wait until Keycloak answers over mutual TLS, then exit");
        return EXIT_CONFIG_ERROR;
    }

    /**
     * Blocks until Keycloak's discovery document is served over mutual TLS or
     * {@code WAIT_TIMEOUT_SECONDS} elapses. Used as an init container so
     * workloads that need Keycloak at start-up do not crash-loop.
     */
    static int waitForKeycloak(Map<String, String> environment, PrintStream out) {
        try {
            Config config = Config.fromEnvironment(environment);
            TlsMaterial tls = TlsMaterial.load(config.certificateFile(), config.keyFile(), config.caFile());
            URI uri = URI.create(config.realmUrl() + "/.well-known/openid-configuration");
            out.println("Waiting up to " + config.waitTimeout().toSeconds() + " s for " + uri);
            try (Http http = new Http(tls.mutualTlsContext(), config.timeout())) {
                Wire.await("Keycloak", config.waitTimeout(), () -> {
                    int status = http.get(uri).status();
                    return status == 200 ? null : "HTTP " + status;
                });
            }
            out.println("Keycloak is reachable over mutual TLS.");
            return EXIT_OK;
        } catch (Config.InvalidConfigException e) {
            out.println("Configuration error: " + e.getMessage());
            return EXIT_CONFIG_ERROR;
        } catch (CheckRunner.CheckFailedException e) {
            out.println(e.getMessage());
            return EXIT_CHECKS_FAILED;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            out.println("Interrupted while waiting for Keycloak");
            return EXIT_CHECKS_FAILED;
        } catch (Exception e) {
            out.println("Cannot load certificate material: " + CheckRunner.describe(e));
            return EXIT_CONFIG_ERROR;
        }
    }

    /** Runs the configured check groups and returns the process exit code. */
    static int run(Map<String, String> environment, PrintStream out) {
        Config config;
        TlsMaterial tls;
        try {
            config = Config.fromEnvironment(environment);
            tls = TlsMaterial.load(config.certificateFile(), config.keyFile(), config.caFile());
        } catch (Config.InvalidConfigException e) {
            out.println("Configuration error: " + e.getMessage());
            return EXIT_CONFIG_ERROR;
        } catch (Exception e) {
            out.println("Cannot load certificate material: " + CheckRunner.describe(e));
            return EXIT_CONFIG_ERROR;
        }

        out.println("== Platform connectivity and certificate test ==");
        out.println("Keycloak : " + config.realmUrl());
        out.println("Issuer   : " + config.expectedIssuer());
        out.println("App      : " + config.appUrl().map(Object::toString).orElse("(not configured)"));
        out.println("Identity : " + tls.clientCertificate().getSubjectX500Principal().getName());
        out.println("Runtime  : Java " + Runtime.version());
        out.println();

        long start = System.nanoTime();
        CheckRunner checks = new CheckRunner(out);
        try (Http mutualTls = new Http(tls.mutualTlsContext(), config.timeout());
                Http serverAuthOnly = new Http(tls.serverAuthOnlyContext(), config.timeout())) {
            if (config.groups().contains("certs")) {
                new CertificateChecks(config, tls).run(checks);
            }
            KeycloakChecks keycloak = new KeycloakChecks(config, mutualTls, serverAuthOnly, tls);
            if (config.groups().contains("keycloak")) {
                keycloak.run(checks);
            }
            if (config.groups().contains("app")) {
                if (config.appUrl().isPresent()) {
                    new AppChecks(config, mutualTls, serverAuthOnly, keycloak).run(checks);
                } else {
                    checks.skip("APP", "Spring Boot app checks", "APP_URL not set");
                }
            }
        } catch (Exception e) {
            out.println("Cannot initialise TLS: " + CheckRunner.describe(e));
            return EXIT_CONFIG_ERROR;
        }

        long failed = checks.count(CheckRunner.Status.FAIL);
        out.println();
        out.printf("Summary: %d passed, %d failed, %d skipped in %.1f s%n",
                checks.count(CheckRunner.Status.PASS), failed, checks.count(CheckRunner.Status.SKIP),
                Duration.ofNanos(System.nanoTime() - start).toMillis() / 1000.0);

        if (config.junitReport().isPresent()) {
            try {
                JunitReport.write(config.junitReport().get(), checks.results());
                out.println("JUnit report: " + config.junitReport().get());
            } catch (Exception e) {
                out.println("Could not write the JUnit report: " + CheckRunner.describe(e));
            }
        }
        return failed == 0 ? EXIT_OK : EXIT_CHECKS_FAILED;
    }
}
