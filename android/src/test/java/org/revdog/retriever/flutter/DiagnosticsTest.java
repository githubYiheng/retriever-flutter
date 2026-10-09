package org.revdog.retriever.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;

/** diagnose 去重与级别（切片 2 简报 §2；对位原生 SDK ConfigDiagnostics 的出口）。 */
public class DiagnosticsTest {
    @Test
    public void dedupesByCodeAndMessageAcrossEngines() {
        final List<String> out = new ArrayList<>();
        Diagnostics d = new Diagnostics(new Diagnostics.Sink() {
            @Override
            public void log(boolean info, String message) {
                out.add((info ? "I " : "W ") + message);
            }
        });
        assertTrue(d.emit("no_key", "Retriever: key is empty"));
        assertFalse("同 (code, message) 第二个引擎再出：去重", d.emit("no_key", "Retriever: key is empty"));
        assertTrue(d.emit("key_malformed", "Retriever: key malformed"));
        assertTrue(d.emit("configure_ignored", "configure ignored: another engine owns Retriever in this process"));
        assertTrue("同 code 不同 message 照出", d.emit("key_rejected", "rejected 401"));
        assertTrue(d.emit("key_rejected", "rejected 403"));
        assertFalse(d.emit(null, "x"));
        assertEquals(Arrays.asList(
                "I Retriever: key is empty",
                "W Retriever: key malformed",
                "W configure ignored: another engine owns Retriever in this process",
                "W rejected 401",
                "W rejected 403"), out);
    }

    @Test
    public void sinkFailureIsSwallowed() {
        Diagnostics d = new Diagnostics(new Diagnostics.Sink() {
            @Override
            public void log(boolean info, String message) {
                throw new RuntimeException("Log not mocked");
            }
        });
        assertTrue(d.emit("no_key", "m"));
    }
}
