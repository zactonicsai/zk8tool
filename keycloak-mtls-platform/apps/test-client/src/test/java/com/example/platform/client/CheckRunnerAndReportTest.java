package com.example.platform.client;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;

import javax.net.ssl.SSLHandshakeException;

import org.junit.jupiter.api.Test;

class CheckRunnerAndReportTest {

    private final ByteArrayOutputStream buffer = new ByteArrayOutputStream();
    private final CheckRunner checks = new CheckRunner(new PrintStream(buffer, true, StandardCharsets.UTF_8));

    @Test
    void recordsPassFailAndSkipWithoutAborting() {
        checks.check("T-01", "passes", () -> "fine");
        checks.check("T-02", "fails an expectation", () -> {
            CheckRunner.require(false, "expected X");
            return "unreachable";
        });
        checks.check("T-03", "throws", () -> {
            throw new IOException("connection refused");
        });
        checks.check("T-04", "skips", () -> CheckRunner.requirePresent(null, "nothing to test"));
        checks.skip("T-05", "explicit skip", "not configured");

        List<CheckRunner.Result> results = checks.results();
        assertEquals(List.of(CheckRunner.Status.PASS, CheckRunner.Status.FAIL, CheckRunner.Status.FAIL,
                CheckRunner.Status.SKIP, CheckRunner.Status.SKIP),
                results.stream().map(CheckRunner.Result::status).toList());
        assertEquals("expected X", results.get(1).detail());
        assertEquals("IOException: connection refused", results.get(2).detail());
        assertEquals(1, checks.count(CheckRunner.Status.PASS));
        assertEquals(2, checks.count(CheckRunner.Status.FAIL));
        assertEquals(2, checks.count(CheckRunner.Status.SKIP));

        String output = buffer.toString(StandardCharsets.UTF_8);
        assertTrue(output.contains("[PASS] T-01"));
        assertTrue(output.contains("[FAIL] T-02"));
        assertTrue(output.contains("[SKIP] T-05"));
    }

    @Test
    void describeShowsTheCauseChainOfTlsFailures() {
        Exception failure = new IOException("handshake failed",
                new SSLHandshakeException("PKIX path building failed"));

        assertEquals("IOException: handshake failed <- SSLHandshakeException: PKIX path building failed",
                CheckRunner.describe(failure));
    }

    @Test
    void junitReportCountsAndEscapes() {
        List<CheckRunner.Result> results = List.of(
                new CheckRunner.Result("KC-01", "ok", CheckRunner.Status.PASS, "fine", Duration.ofMillis(1500)),
                new CheckRunner.Result("KC-02", "bad <tag> & \"quote\"", CheckRunner.Status.FAIL, "a<b\nline2",
                        Duration.ofMillis(500)),
                new CheckRunner.Result("APP-01", "skipped", CheckRunner.Status.SKIP, null, Duration.ZERO));

        String xml = JunitReport.render(results);

        assertTrue(xml.contains("tests=\"3\" failures=\"1\" skipped=\"1\" time=\"2.000\""));
        assertTrue(xml.contains("classname=\"KC\" name=\"KC-01 ok\" time=\"1.500\"/>"));
        assertTrue(xml.contains("name=\"KC-02 bad &lt;tag&gt; &amp; &quot;quote&quot;\""));
        assertTrue(xml.contains("<failure message=\"a&lt;b line2\"/>"));
        assertTrue(xml.contains("classname=\"APP\""));
        assertTrue(xml.contains("<skipped message=\"\"/>"));
        assertFalse(xml.contains("<tag>"));
    }

    @Test
    void junitReportIsWellFormedAndWritten() throws Exception {
        Path directory = Files.createTempDirectory("report");
        Path file = directory.resolve("nested/report.xml");
        try {
            JunitReport.write(file, List.of(new CheckRunner.Result("CERT-01", "x", CheckRunner.Status.FAIL,
                    "weird \u0001 control & <chars>", Duration.ofMillis(3))));

            assertEquals("testsuite", Wire.parseXml(Files.readString(file)).getDocumentElement().getTagName());
        } finally {
            Files.deleteIfExists(file);
            Files.deleteIfExists(file.getParent());
            Files.deleteIfExists(directory);
        }
    }
}
