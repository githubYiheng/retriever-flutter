package org.revdog.retriever.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class PlatformInfoTest {
    @Test
    public void autoProcessName() {
        assertEquals("main", PlatformInfo.autoProcessName("com.example.app", "com.example.app"));
        assertEquals("main", PlatformInfo.autoProcessName(null, "com.example.app"));
        assertEquals("main", PlatformInfo.autoProcessName("", "com.example.app"));
        assertEquals("remote", PlatformInfo.autoProcessName("com.example.app:remote", "com.example.app"));
        assertEquals("other.proc", PlatformInfo.autoProcessName("other.proc", "com.example.app"));
    }

    @Test
    public void tokenIsLowercaseUuid() {
        assertTrue(PlatformInfo.TOKEN.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"));
    }
}
