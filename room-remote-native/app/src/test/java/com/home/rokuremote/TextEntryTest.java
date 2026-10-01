package com.home.rokuremote;

import org.junit.Test;
import static org.junit.Assert.*;

public class TextEntryTest {
    // ECP-2 carries the raw character in param-key. Percent-encoding (the HTTP-URL
    // convention) is answered with 400 Bad Request by the TV, so it must not be used.
    @Test public void charactersAreSentRawNotPercentEncoded() {
        assertEquals("Lit_a", RemoteService.literalKey('a'));
        assertEquals("Lit_Z", RemoteService.literalKey('Z'));
        assertEquals("Lit_7", RemoteService.literalKey('7'));
        assertEquals("Lit_ ", RemoteService.literalKey(' '));
        assertEquals("Lit_.", RemoteService.literalKey('.'));
        assertEquals("Lit_!", RemoteService.literalKey('!'));
    }

    @Test public void unsendableCharactersAreDropped() {
        assertNull(RemoteService.literalKey('\n'));
        assertNull(RemoteService.literalKey('\t'));
        assertNull(RemoteService.literalKey((char) 0));
        assertNull(RemoteService.literalKey('é'));
    }

    @Test public void everyProducedKeyIsAcceptedByTheWhitelist() {
        String sample = "Stranger Things 4! (2022) \"best\" 50% off_now";
        for (char c : sample.toCharArray()) {
            String key = RemoteService.literalKey(c);
            if (key == null) continue;
            assertTrue("rejected " + key + " for char " + c, RokuClient.isSupportedKey(key));
        }
    }

    // A typed quote or backslash must not be able to break out of the JSON payload.
    @Test public void jsonEscapingProtectsThePayload() {
        assertEquals("Lit_\\\"", RokuSession.jsonEscape("Lit_\""));
        assertEquals("Lit_\\\\", RokuSession.jsonEscape("Lit_\\"));
        assertEquals("Lit_a", RokuSession.jsonEscape("Lit_a"));
        assertEquals("Home", RokuSession.jsonEscape("Home"));
    }
}
