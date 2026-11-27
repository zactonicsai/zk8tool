package com.example.platform.client;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSession;

/**
 * Thin wrapper around {@link HttpClient} bound to one TLS identity. Redirects
 * are never followed (the checks assert on them) and the JDK's default
 * hostname verification stays on.
 */
final class Http implements AutoCloseable {

    /** Status, headers, body and the negotiated TLS session of one exchange. */
    record Response(int status, java.net.http.HttpHeaders headers, String body, Optional<SSLSession> tls) {

        Optional<String> header(String name) {
            return headers.firstValue(name);
        }
    }

    private final HttpClient client;
    private final Duration timeout;

    Http(SSLContext sslContext, Duration timeout) {
        SSLParameters parameters = new SSLParameters();
        parameters.setProtocols(new String[] {"TLSv1.3", "TLSv1.2"});
        this.timeout = timeout;
        this.client = HttpClient.newBuilder()
                .sslContext(sslContext)
                .sslParameters(parameters)
                .version(HttpClient.Version.HTTP_1_1)
                .followRedirects(HttpClient.Redirect.NEVER)
                .connectTimeout(timeout)
                .build();
    }

    Response get(URI uri) throws IOException, InterruptedException {
        return get(uri, Map.of());
    }

    Response get(URI uri, Map<String, String> headers) throws IOException, InterruptedException {
        HttpRequest.Builder request = HttpRequest.newBuilder(uri).timeout(timeout).GET();
        headers.forEach(request::header);
        return send(request.build());
    }

    Response postForm(URI uri, Map<String, String> form) throws IOException, InterruptedException {
        String body = form.entrySet().stream()
                .map(e -> encode(e.getKey()) + "=" + encode(e.getValue()))
                .collect(Collectors.joining("&"));
        return send(HttpRequest.newBuilder(uri).timeout(timeout)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("Accept", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build());
    }

    private Response send(HttpRequest request) throws IOException, InterruptedException {
        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
        return new Response(response.statusCode(), response.headers(), response.body(), response.sslSession());
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    @Override
    public void close() {
        client.close();
    }
}
