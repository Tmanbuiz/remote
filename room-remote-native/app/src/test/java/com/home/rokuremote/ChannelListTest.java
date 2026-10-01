package com.home.rokuremote;

import org.junit.Test;
import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;
import java.util.List;

public class ChannelListTest {
    // Trimmed from the real reply of a Hisense Roku TV, including the non-breaking
    // spaces the TV puts in input names and an escaped ampersand.
    private static final String REAL =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<apps>\n"
        + "\t<app id=\"tvinput.hdmi1\" type=\"tvin\" version=\"1.0.0\">HDMI 1 (eARC)</app>\n"
        + "\t<app id=\"tvinput.dtv\" type=\"tvin\" version=\"1.0.0\">Live TV</app>\n"
        + "\t<app id=\"12\" type=\"appl\" subtype=\"rsga\" version=\"61.2523\">Netflix</app>\n"
        + "\t<app id=\"13\" type=\"appl\" subtype=\"rsga\" version=\"12.0\">Prime Video</app>\n"
        + "\t<app id=\"837\" type=\"appl\" subtype=\"rsga\" version=\"2.7\">YouTube</app>\n"
        + "\t<app id=\"41468\" type=\"appl\" subtype=\"rsga\" version=\"9.9\">Tubi - Free Movies &amp; TV</app>\n"
        + "</apps>";

    private List<RokuSession.Channel> parse(String xml) throws Exception {
        return RokuSession.parseChannels(xml.getBytes(StandardCharsets.UTF_8));
    }

    @Test public void readsChannelsAndInputs() throws Exception {
        List<RokuSession.Channel> list = parse(REAL);
        assertEquals(6, list.size());
        assertEquals("tvinput.hdmi1", list.get(0).id);
        assertTrue("HDMI should be flagged as an input", list.get(0).input);
        assertEquals("12", list.get(2).id);
        assertEquals("Netflix", list.get(2).name);
        assertFalse("Netflix is not an input", list.get(2).input);
    }

    // The TV separates words with non-breaking spaces; they must not survive as  .
    @Test public void normalisesNonBreakingSpaces() throws Exception {
        List<RokuSession.Channel> list = parse(REAL);
        assertEquals("HDMI 1 (eARC)", list.get(0).name);
        assertEquals("Live TV", list.get(1).name);
    }

    @Test public void decodesEscapedEntities() throws Exception {
        List<RokuSession.Channel> list = parse(REAL);
        assertEquals("Tubi - Free Movies & TV", list.get(5).name);
    }

    @Test public void rejectsUnsafeOrMalformedXml() {
        String[] bad = {
            "<!DOCTYPE apps [<!ENTITY x SYSTEM 'file:///private'>]><apps><app id=\"1\">&x;</app></apps>",
            "<apps><app id=\"1\">Broken",
        };
        for (String xml : bad) {
            try { parse(xml); fail("accepted unsafe XML: " + xml); } catch (Exception expected) { }
        }
    }

    @Test public void channelIdsAreValidated() {
        assertTrue(RokuSession.isChannelId("12"));
        assertTrue(RokuSession.isChannelId("tvinput.hdmi1"));
        assertFalse(RokuSession.isChannelId(""));
        assertFalse(RokuSession.isChannelId(null));
        // must not allow anything that could break out of the JSON payload
        assertFalse(RokuSession.isChannelId("12\",\"x\":\""));
        assertFalse(RokuSession.isChannelId("../../etc"));
    }
}
