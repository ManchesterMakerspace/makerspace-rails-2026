package org.makerspace.keyfobbit;

import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;

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
    private String cookie;

    ApiClient(String baseUrl) {
        String clean = baseUrl.trim();
        this.baseUrl = clean.endsWith("/") ? clean.substring(0, clean.length() - 1) : clean;
    }

    Response post(String path, JSONObject json) throws IOException { return request("POST", path, json); }
    Response get(String path) throws IOException { return request("GET", path, null); }

    private Response request(String method, String path, JSONObject json) throws IOException {
        HttpURLConnection connection = (HttpURLConnection) new URL(baseUrl + path).openConnection();
        connection.setRequestMethod(method);
        connection.setConnectTimeout(15000);
        connection.setReadTimeout(15000);
        connection.setRequestProperty("Accept", "application/json");
        if (cookie != null) connection.setRequestProperty("Cookie", cookie);
        if (json != null) {
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            try (OutputStream out = connection.getOutputStream()) {
                out.write(json.toString().getBytes(StandardCharsets.UTF_8));
            }
        }
        int status = connection.getResponseCode();
        captureCookie(connection.getHeaderField("Set-Cookie"));
        InputStream stream = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
        String text = read(stream);
        connection.disconnect();
        try { return new Response(status, text.isEmpty() ? new JSONObject() : new JSONObject(text)); }
        catch (Exception malformed) { return new Response(status, new JSONObject()); }
    }

    private void captureCookie(String header) {
        if (header == null || header.isEmpty()) return;
        cookie = header.split(";", 2)[0];
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
