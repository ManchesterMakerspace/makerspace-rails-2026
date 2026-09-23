package org.makerspace.keyfobbit;

import static org.junit.Assert.assertEquals;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.Test;

public class CookieJarTest {
    @Test public void mergesCookiesAndDecodesCsrfToken() {
        CookieJar jar = new CookieJar();
        jar.capture(headers("Set-Cookie", "_member-interface_session=session-one; Path=/"));
        jar.capture(headers("set-cookie", "XSRF-TOKEN=a%2Bb%3D%3D; Path=/"));

        assertEquals("_member-interface_session=session-one; XSRF-TOKEN=a%2Bb%3D%3D", jar.header());
        assertEquals("a+b==", jar.csrfToken());
    }

    @Test public void capturesEverySetCookieHeaderAndReplacesOnlyMatchingNames() {
        CookieJar jar = new CookieJar();
        jar.capture(headers("Set-Cookie", "session=old; Path=/", "preference=compact; Path=/"));
        jar.capture(headers("Set-Cookie", "session=new; Path=/"));

        assertEquals("session=new; preference=compact", jar.header());
    }

    private static Map<String, List<String>> headers(String name, String... values) {
        Map<String, List<String>> headers = new LinkedHashMap<>();
        headers.put(name, Arrays.asList(values));
        return headers;
    }
}
