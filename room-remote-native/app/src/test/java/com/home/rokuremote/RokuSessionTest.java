package com.home.rokuremote;

import org.junit.Test;
import static org.junit.Assert.*;
import java.io.ByteArrayInputStream;

public class RokuSessionTest {
    // Known ECP-2 vector: this challenge/response pair comes from a captured
    // official-app handshake and pins the derived AUTH_KEY end to end.
    @Test public void authResponseMatchesKnownVector() throws Exception {
        assertEquals("6yYiyDKcbca3qwig1hylU0dHqUQ=",
            RokuSession.authResponse("3KwH7h3HTmxFziLtrzVg5w=="));
    }

    // RFC 6455 §1.3 canonical example.
    @Test public void websocketAcceptMatchesRfcExample() throws Exception {
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            RokuSession.expectedAccept("dGhlIHNhbXBsZSBub25jZQ=="));
    }

    @Test public void frameRoundTripsThroughReader() throws Exception {
        byte[] payload = "{\"request\":\"key-press\",\"param-key\":\"Home\"}".getBytes("UTF-8");
        byte[] mask = {0x11, 0x22, 0x33, 0x44};
        byte[] frame = RokuSession.buildFrame(0x1, payload, mask);
        // client frames must set FIN and the mask bit
        assertEquals((byte) 0x81, frame[0]);
        assertTrue((frame[1] & 0x80) != 0);
        RokuSession.Frame parsed = RokuSession.readFrame(new ByteArrayInputStream(frame));
        assertEquals(0x1, parsed.opcode);
        assertArrayEquals(payload, parsed.payload);
    }

    @Test public void frameSupportsExtended16BitLength() throws Exception {
        byte[] payload = new byte[300];
        for (int i = 0; i < payload.length; i++) payload[i] = (byte) (i & 0x7F);
        byte[] mask = {0x01, 0x02, 0x03, 0x04};
        RokuSession.Frame parsed = RokuSession.readFrame(
            new ByteArrayInputStream(RokuSession.buildFrame(0x1, payload, mask)));
        assertArrayEquals(payload, parsed.payload);
    }

    // The TV answers 202 Accepted to power keys; only non-2xx is a real refusal.
    @Test public void anySuccessStatusIsAccepted() {
        assertTrue(RokuSession.accepted("200"));
        assertTrue(RokuSession.accepted("202"));
        assertTrue(RokuSession.accepted("204"));
        assertFalse(RokuSession.accepted("400"));
        assertFalse(RokuSession.accepted("403"));
        assertFalse(RokuSession.accepted(null));
        assertFalse(RokuSession.accepted("OK"));
        assertFalse(RokuSession.accepted(""));
    }

    @Test public void jsonFieldReadsFlatValues() {
        String msg = "{\"response\":\"key-press\",\"response-id\":\"7\",\"status\":\"200\",\"status-msg\":\"OK\"}";
        assertEquals("7", RokuSession.jsonField(msg, "response-id"));
        assertEquals("200", RokuSession.jsonField(msg, "status"));
        assertEquals("key-press", RokuSession.jsonField(msg, "response"));
        assertNull(RokuSession.jsonField(msg, "missing"));
    }
}
