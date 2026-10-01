package com.home.rokuremote;

import org.junit.Test;
import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;

public class RokuClientTest {
    @Test public void acceptsPrivateAddresses() {
        for (String ip : new String[]{"10.0.0.2", "172.16.1.1", "172.31.255.254", "192.168.1.20", "169.254.1.2"})
            assertEquals(ip, RokuClient.validateHost(" " + ip + " "));
    }
    @Test public void rejectsPublicOrMalformedTargets() {
        for (String ip : new String[]{"8.8.8.8", "127.0.0.1", "172.32.0.1", "192.168.1.999", "192.168.01.1", "192.168.1.1:8060", "http://192.168.1.1", "localhost", "1.2.3", "", "192.168.1.1/path"}) {
            try { RokuClient.validateHost(ip); fail("Accepted " + ip); } catch (IllegalArgumentException expected) { }
        }
    }
    @Test public void ssdpRequiresSuccessfulRokuResponse() {
        assertTrue(RokuClient.isRokuResponse("HTTP/1.1 200 OK\r\nSt: roku:ecp\r\n\r\n"));
        assertFalse(RokuClient.isRokuResponse("HTTP/1.1 404 Not Found\r\nST: roku:ecp\r\n"));
        assertFalse(RokuClient.isRokuResponse("HTTP/1.1 200 OK\r\nST: another-device\r\n"));
        assertFalse(RokuClient.isRokuResponse("HTTP/1.1 200 OK\r\nLOCATION: http://roku:ecp\r\n"));
    }
    @Test public void parsesIdentityAndEscapedName() throws Exception {
        RokuClient.Device device = parse("<device-info><serial-number>ABC123</serial-number><user-device-name>Living &amp; dining</user-device-name></device-info>");
        assertEquals("ABC123", device.serial); assertEquals("Living & dining", device.name);
    }
    @Test public void usesModelWhenNameMissing() throws Exception {
        assertEquals("Hisense Roku TV", parse("<device-info><serial-number>123</serial-number><model-name>Hisense Roku TV</model-name></device-info>").name);
    }
    @Test public void rejectsSpoofedOrUnsafeXml() {
        for (String xml : new String[]{"<other><serial-number>123</serial-number></other>", "<device-info/>",
            "<!DOCTYPE device-info [<!ENTITY x SYSTEM 'file:///private'>]><device-info><serial-number>&x;</serial-number></device-info>", "<device-info><serial-number>123"}) {
            try { parse(xml); fail("Accepted invalid XML"); } catch (Exception expected) { }
        }
    }
    @Test public void acceptsFullKeySetAndLiteralKeys() {
        RokuClient client = new RokuClient();
        // A supported key gets past the whitelist and is stopped only by the host guard.
        for (String key : new String[]{"Home", "Back", "Left", "Right", "Select", "Play", "Pause",
                "Search", "Enter", "Backspace", "FindRemote", "ChannelUp", "ChannelDown",
                "PowerOn", "PowerOff", "InputHDMI1", "InputAV1", "Lit_a", "Lit_Z", "Lit_%20"}) {
            try { client.key("8.8.8.8", key); fail("Expected host rejection for " + key); }
            catch (IllegalArgumentException e) { assertTrue("Whitelist rejected " + key, e.getMessage().contains("local-network")); }
            catch (Exception e) { fail("Unexpected " + e + " for " + key); }
        }
        for (String key : new String[]{"Reboot", "Lit_", "Lit_ab", "Lit_%2", "", "home"}) {
            try { client.key("8.8.8.8", key); fail("Accepted bad key " + key); }
            catch (IllegalArgumentException e) { assertTrue("Wrong guard for " + key, e.getMessage().contains("Unsupported remote button")); }
            catch (Exception e) { fail("Unexpected " + e + " for " + key); }
        }
    }
    private RokuClient.Device parse(String xml) throws Exception { return RokuClient.parseDevice("192.168.1.2", xml.getBytes(StandardCharsets.UTF_8)); }
}
