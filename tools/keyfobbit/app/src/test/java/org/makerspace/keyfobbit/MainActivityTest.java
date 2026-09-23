package org.makerspace.keyfobbit;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public class MainActivityTest {
    @Test public void formatsUidAsUppercaseZeroPaddedHex() {
        assertEquals("000A80FF", MainActivity.uidHex(new byte[] { 0, 10, (byte) 128, (byte) 255 }));
    }
}
