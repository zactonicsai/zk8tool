package com.example.platform.client;

import static com.example.platform.client.CheckRunner.require;

import java.io.IOException;
import java.io.StringReader;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSession;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.parsers.ParserConfigurationException;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;

/** Helpers shared by the Keycloak and app checks: TLS session inspection, safe XML parsing, waiting. */
final class Wire {

    static final String SAML_METADATA_NS = "urn:oasis:names:tc:SAML:2.0:metadata";
    static final String XML_DSIG_NS = "http://www.w3.org/2000/09/xmldsig#";

    private Wire() {
    }

    /**
     * Asserts on the TLS session of a response: negotiated protocol and the
     * remaining lifetime of the server certificate. Chain and hostname were
     * already verified by the JDK during the handshake, against our CA only.
     */
    static String tlsSummary(String label, Http.Response response, Config config) throws SSLPeerUnverifiedException {
        SSLSession session = response.tls()
                .orElseThrow(() -> new CheckRunner.CheckFailedException(label + " did not answer over TLS"));
        require(config.tlsProtocols().contains(session.getProtocol()), label + " negotiated "
                + session.getProtocol() + " but only " + config.tlsProtocols() + " is accepted");
        Certificate[] peer = session.getPeerCertificates();
        require(peer.length > 0 && peer[0] instanceof X509Certificate, label + " presented no X.509 certificate");
        String validity = CertificateChecks.validity(label, (X509Certificate) peer[0], config.minValidity());
        return session.getProtocol() + " " + session.getCipherSuite() + "; " + validity;
    }

    /** Parses XML with DTDs, external entities and XInclude disabled (no XXE, no entity expansion). */
    static Document parseXml(String xml) throws ParserConfigurationException, SAXException, IOException {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
        factory.setXIncludeAware(false);
        factory.setExpandEntityReferences(false);
        return factory.newDocumentBuilder().parse(new InputSource(new StringReader(xml)));
    }

    static List<Element> elements(Document document, String namespace, String localName) {
        NodeList nodes = document.getElementsByTagNameNS(namespace, localName);
        List<Element> elements = new ArrayList<>();
        for (int i = 0; i < nodes.getLength(); i++) {
            elements.add((Element) nodes.item(i));
        }
        return elements;
    }

    /** Result of one readiness probe. */
    @FunctionalInterface
    interface Probe {
        /** @return null when ready, otherwise a short description of why not */
        String attempt() throws Exception;
    }

    /**
     * Polls {@code probe} every two seconds until it reports ready or
     * {@code timeout} elapses. Lets the test pod start before its targets.
     */
    static void await(String what, Duration timeout, Probe probe) throws InterruptedException {
        long deadline = System.nanoTime() + timeout.toNanos();
        String last;
        while (true) {
            try {
                last = probe.attempt();
            } catch (InterruptedException e) {
                throw e;
            } catch (Exception e) {
                last = CheckRunner.describe(e);
            }
            if (last == null) {
                return;
            }
            if (System.nanoTime() >= deadline) {
                throw new CheckRunner.CheckFailedException(
                        what + " not ready after " + timeout.toSeconds() + " s: " + last);
            }
            Thread.sleep(2000);
        }
    }
}
