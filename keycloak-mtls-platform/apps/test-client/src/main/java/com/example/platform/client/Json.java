package com.example.platform.client;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Small, strict JSON reader (RFC 8259) so the test client needs no third-party
 * library. Objects become {@link Map}, arrays {@link List}, numbers
 * {@link Long} or {@link Double}, plus {@link String}, {@link Boolean} and null.
 */
final class Json {

    /** Guards against stack exhaustion on hostile input. */
    private static final int MAX_DEPTH = 64;

    private final String text;
    private int position;

    private Json(String text) {
        this.text = text;
    }

    static Object parse(String text) {
        Json parser = new Json(text);
        parser.skipWhitespace();
        Object value = parser.readValue(0);
        parser.skipWhitespace();
        if (parser.position != text.length()) {
            throw parser.error("Unexpected trailing content");
        }
        return value;
    }

    /** Parses a document whose root must be an object. */
    static Map<String, Object> parseObject(String text) {
        return asObject(parse(text));
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> asObject(Object value) {
        if (value instanceof Map<?, ?> map) {
            return (Map<String, Object>) map;
        }
        throw new IllegalArgumentException("Expected a JSON object but got: " + describe(value));
    }

    @SuppressWarnings("unchecked")
    static List<Object> asArray(Object value) {
        if (value instanceof List<?> list) {
            return (List<Object>) list;
        }
        throw new IllegalArgumentException("Expected a JSON array but got: " + describe(value));
    }

    /** String member of an object, or null when absent or not a string. */
    static String string(Map<String, Object> object, String key) {
        return object.get(key) instanceof String value ? value : null;
    }

    /**
     * A claim that may be a single string or an array of strings (JWT "aud").
     * Absent or differently typed values give an empty list.
     */
    static List<String> stringList(Object value) {
        return switch (value) {
            case String single -> List.of(single);
            case List<?> list -> list.stream().filter(String.class::isInstance).map(String.class::cast).toList();
            case null, default -> List.of();
        };
    }

    private static String describe(Object value) {
        return value == null ? "null" : value.getClass().getSimpleName();
    }

    private Object readValue(int depth) {
        if (depth > MAX_DEPTH) {
            throw error("Nesting deeper than " + MAX_DEPTH);
        }
        if (position >= text.length()) {
            throw error("Unexpected end of input");
        }
        char c = text.charAt(position);
        return switch (c) {
            case '{' -> readObject(depth);
            case '[' -> readArray(depth);
            case '"' -> readString();
            case 't' -> readLiteral("true", Boolean.TRUE);
            case 'f' -> readLiteral("false", Boolean.FALSE);
            case 'n' -> readLiteral("null", null);
            default -> {
                if (c == '-' || (c >= '0' && c <= '9')) {
                    yield readNumber();
                }
                throw error("Unexpected character '" + c + "'");
            }
        };
    }

    private Map<String, Object> readObject(int depth) {
        Map<String, Object> object = new LinkedHashMap<>();
        position++; // {
        skipWhitespace();
        if (peek() == '}') {
            position++;
            return object;
        }
        while (true) {
            skipWhitespace();
            if (peek() != '"') {
                throw error("Expected a string key");
            }
            String key = readString();
            skipWhitespace();
            expect(':');
            skipWhitespace();
            object.put(key, readValue(depth + 1));
            skipWhitespace();
            char c = next();
            if (c == '}') {
                return object;
            }
            if (c != ',') {
                throw error("Expected ',' or '}'");
            }
        }
    }

    private List<Object> readArray(int depth) {
        List<Object> array = new ArrayList<>();
        position++; // [
        skipWhitespace();
        if (peek() == ']') {
            position++;
            return array;
        }
        while (true) {
            skipWhitespace();
            array.add(readValue(depth + 1));
            skipWhitespace();
            char c = next();
            if (c == ']') {
                return array;
            }
            if (c != ',') {
                throw error("Expected ',' or ']'");
            }
        }
    }

    private String readString() {
        StringBuilder builder = new StringBuilder();
        position++; // opening quote
        while (true) {
            char c = next();
            switch (c) {
                case '"' -> {
                    return builder.toString();
                }
                case '\\' -> builder.append(readEscape());
                default -> {
                    if (c < 0x20) {
                        throw error("Unescaped control character in string");
                    }
                    builder.append(c);
                }
            }
        }
    }

    private char readEscape() {
        char c = next();
        return switch (c) {
            case '"', '\\', '/' -> c;
            case 'b' -> '\b';
            case 'f' -> '\f';
            case 'n' -> '\n';
            case 'r' -> '\r';
            case 't' -> '\t';
            case 'u' -> {
                if (position + 4 > text.length()) {
                    throw error("Truncated \\u escape");
                }
                String hex = text.substring(position, position + 4);
                position += 4;
                try {
                    yield (char) Integer.parseInt(hex, 16);
                } catch (NumberFormatException e) {
                    throw error("Invalid \\u escape '" + hex + "'");
                }
            }
            default -> throw error("Invalid escape '\\" + c + "'");
        };
    }

    private Object readNumber() {
        int start = position;
        boolean integral = true;
        if (peek() == '-') {
            position++;
        }
        while (position < text.length()) {
            char c = text.charAt(position);
            if (c >= '0' && c <= '9') {
                position++;
            } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                integral = false;
                position++;
            } else {
                break;
            }
        }
        String number = text.substring(start, position);
        try {
            if (integral) {
                return Long.parseLong(number);
            }
            return Double.parseDouble(number);
        } catch (NumberFormatException e) {
            throw error("Invalid number '" + number + "'");
        }
    }

    private Object readLiteral(String literal, Object value) {
        if (!text.startsWith(literal, position)) {
            throw error("Expected '" + literal + "'");
        }
        position += literal.length();
        return value;
    }

    private void skipWhitespace() {
        while (position < text.length()) {
            char c = text.charAt(position);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                position++;
            } else {
                return;
            }
        }
    }

    private char peek() {
        if (position >= text.length()) {
            throw error("Unexpected end of input");
        }
        return text.charAt(position);
    }

    private char next() {
        char c = peek();
        position++;
        return c;
    }

    private void expect(char expected) {
        if (next() != expected) {
            throw error("Expected '" + expected + "'");
        }
    }

    private IllegalArgumentException error(String message) {
        return new IllegalArgumentException("Invalid JSON at offset " + position + ": " + message);
    }
}
