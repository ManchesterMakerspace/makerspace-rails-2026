package org.makerspace.keyfobbit;

import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** A minimal single-origin cookie jar for the configured Makerspace server. */
final class CookieJar {
    private final Map<String, String> cookies = new LinkedHashMap<>();

    void capture(Map<String, List<String>> headers) {
        for (Map.Entry<String, List<String>> entry : headers.entrySet()) {
            if (entry.getKey() == null || !entry.getKey().equalsIgnoreCase("Set-Cookie")) continue;
            for (String header : entry.getValue()) {
                String pair = header.split(";", 2)[0];
                String[] parts = pair.split("=", 2);
                if (parts.length == 2) cookies.put(parts[0].trim(), parts[1].trim());
            }
        }
    }

    String header() {
        StringBuilder result = new StringBuilder();
        for (Map.Entry<String, String> cookie : cookies.entrySet()) {
            if (result.length() > 0) result.append("; ");
            result.append(cookie.getKey()).append('=').append(cookie.getValue());
        }
        return result.toString();
    }

    String csrfToken() {
        String token = cookies.get("XSRF-TOKEN");
        if (token == null) return null;
        try {
            return URLDecoder.decode(token, StandardCharsets.UTF_8.name());
        } catch (UnsupportedEncodingException impossible) {
            throw new AssertionError(impossible);
        }
    }
}
