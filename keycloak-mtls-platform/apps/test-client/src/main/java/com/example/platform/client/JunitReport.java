package com.example.platform.client;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;

/** Writes the results as a JUnit XML report so CI systems can display them. */
final class JunitReport {

    private JunitReport() {
    }

    static void write(Path file, List<CheckRunner.Result> results) throws IOException {
        if (file.toAbsolutePath().getParent() != null) {
            Files.createDirectories(file.toAbsolutePath().getParent());
        }
        Files.writeString(file, render(results), StandardCharsets.UTF_8);
    }

    static String render(List<CheckRunner.Result> results) {
        long failures = results.stream().filter(r -> r.status() == CheckRunner.Status.FAIL).count();
        long skipped = results.stream().filter(r -> r.status() == CheckRunner.Status.SKIP).count();
        double seconds = results.stream().mapToLong(r -> r.duration().toMillis()).sum() / 1000.0;

        StringBuilder xml = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        xml.append(String.format(Locale.ROOT,
                "<testsuite name=\"platform-connectivity\" tests=\"%d\" failures=\"%d\" skipped=\"%d\" time=\"%.3f\">%n",
                results.size(), failures, skipped, seconds));
        for (CheckRunner.Result result : results) {
            xml.append(String.format(Locale.ROOT, "  <testcase classname=\"%s\" name=\"%s\" time=\"%.3f\"",
                    escape(group(result.id())), escape(result.id() + " " + result.title()),
                    result.duration().toMillis() / 1000.0));
            String detail = escape(result.detail() == null ? "" : result.detail());
            switch (result.status()) {
                case PASS -> xml.append("/>\n");
                case FAIL -> xml.append(">\n    <failure message=\"").append(detail).append("\"/>\n  </testcase>\n");
                case SKIP -> xml.append(">\n    <skipped message=\"").append(detail).append("\"/>\n  </testcase>\n");
            }
        }
        return xml.append("</testsuite>\n").toString();
    }

    private static String group(String id) {
        int dash = id.indexOf('-');
        return dash < 0 ? id : id.substring(0, dash);
    }

    static String escape(String value) {
        StringBuilder escaped = new StringBuilder(value.length());
        for (char c : value.toCharArray()) {
            switch (c) {
                case '&' -> escaped.append("&amp;");
                case '<' -> escaped.append("&lt;");
                case '>' -> escaped.append("&gt;");
                case '"' -> escaped.append("&quot;");
                case '\n', '\r', '\t' -> escaped.append(' ');
                default -> {
                    if (c >= 0x20) {
                        escaped.append(c);
                    }
                }
            }
        }
        return escaped.toString();
    }
}
