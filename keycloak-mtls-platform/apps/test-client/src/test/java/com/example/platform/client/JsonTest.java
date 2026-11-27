package com.example.platform.client;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

class JsonTest {

    @Test
    void parsesNestedObjectsArraysAndScalars() {
        Map<String, Object> document = Json.parseObject("""
                { "issuer": "https://sso/realms/platform",
                  "expires_in": 120, "ratio": -1.5e2, "active": true, "none": null,
                  "aud": ["a", "b"], "cnf": { "x5t#S256": "abc" }, "empty": {}, "list": [] }
                """);

        assertEquals("https://sso/realms/platform", document.get("issuer"));
        assertEquals(120L, document.get("expires_in"));
        assertEquals(-150.0, document.get("ratio"));
        assertEquals(Boolean.TRUE, document.get("active"));
        assertTrue(document.containsKey("none"));
        assertNull(document.get("none"));
        assertEquals(List.of("a", "b"), document.get("aud"));
        assertEquals(Map.of("x5t#S256", "abc"), document.get("cnf"));
        assertEquals(Map.of(), document.get("empty"));
        assertEquals(List.of(), document.get("list"));
    }

    @Test
    void decodesStringEscapes() {
        assertEquals("a\"b\\c/d\n\t\u00e9", Json.parse("\"a\\\"b\\\\c\\/d\\n\\t\\u00e9\""));
    }

    @Test
    void rejectsMalformedDocuments() {
        for (String invalid : List.of("", "{", "{\"a\":}", "{\"a\":1,}", "[1 2]", "{'a':1}", "nul",
                "{\"a\":1} trailing", "\"unterminated", "\"bad\\x\"", "\"\\u12\"", "--1")) {
            assertThrows(IllegalArgumentException.class, () -> Json.parse(invalid));
        }
    }

    @Test
    void rejectsExcessiveNesting() {
        String deep = "[".repeat(200) + "]".repeat(200);

        assertThrows(IllegalArgumentException.class, () -> Json.parse(deep));
    }

    @Test
    void rootMustBeAnObjectWhenRequested() {
        assertThrows(IllegalArgumentException.class, () -> Json.parseObject("[1]"));
    }

    @Test
    void stringListAcceptsSingleValueArrayOrNothing() {
        assertEquals(List.of("spring-app"), Json.stringList("spring-app"));
        assertEquals(List.of("a", "b"), Json.stringList(List.of("a", 1, "b")));
        assertEquals(List.of(), Json.stringList(null));
        assertEquals(List.of(), Json.stringList(42));
    }

    @Test
    void stringReturnsNullForMissingOrNonStringMembers() {
        Map<String, Object> document = Json.parseObject("{\"a\":\"x\",\"b\":1}");

        assertEquals("x", Json.string(document, "a"));
        assertNull(Json.string(document, "b"));
        assertNull(Json.string(document, "missing"));
    }
}
