package org.makerspace.keyfobbit;

import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

final class ApiClient {
    static final class Response {
        final int status;
        final JSONObject body;
        Response(int status, JSONObject body) { this.status = status; this.body = body; }
        String message() {
            String value = body.optString("message", body.optString("error", "Request failed (HTTP " + status + ")"));
            return value.isEmpty() ? "Request failed (HTTP " + status + ")" : value;
        }
    }

    private final String baseUrl;
    private final CookieJar cookies = new CookieJar();

    ApiClient(String baseUrl) {
        String clean = baseUrl.trim();
        this.baseUrl = clean.endsWith("/") ? clean.substring(0, clean.length() - 1) : clean;
    }

    Response post(String path, JSONObject json) throws IOException { return request("POST", path, json); }
    Response get(String path) throws IOException { return request("GET", path, null); }

    private Response request(String method, String path, JSONObject json) throws IOException {
        if (!method.equals("GET") && cookies.csrfToken() == null) {
            // Rails issues the CSRF cookie on safe requests. Bootstrap it before
            // the first login write as well as reusing refreshed tokens later.
            request("GET", "/api/config", null);
        }
        HttpURLConnection connection = (HttpURLConnection) new URL(baseUrl + path).openConnection();
        connection.setRequestMethod(method);
        connection.setConnectTimeout(15000);
        connection.setReadTimeout(15000);
        connection.setRequestProperty("Accept", "application/json");
        String cookieHeader = cookies.header();
        if (!cookieHeader.isEmpty()) connection.setRequestProperty("Cookie", cookieHeader);
        if (json != null) {
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            String csrfToken = cookies.csrfToken();
            if (csrfToken != null) connection.setRequestProperty("X-XSRF-TOKEN", csrfToken);
            try (OutputStream out = connection.getOutputStream()) {
                out.write(json.toString().getBytes(StandardCharsets.UTF_8));
            }
        }
        int status = connection.getResponseCode();
        cookies.capture(connection.getHeaderFields());
        InputStream stream = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
        String text = read(stream);
        connection.disconnect();
        try { return new Response(status, text.isEmpty() ? new JSONObject() : new JSONObject(text)); }
        catch (Exception malformed) { return new Response(status, new JSONObject()); }
    }

    private static String read(InputStream stream) throws IOException {
        if (stream == null) return "";
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = stream.read(buffer)) != -1) result.write(buffer, 0, count);
        stream.close();
        return result.toString(StandardCharsets.UTF_8.name());
    }
}
