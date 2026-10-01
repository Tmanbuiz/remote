package com.home.rokuremote;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserFactory;

/** Local network transport. Never follows redirects or accepts public IP addresses. */
public final class RokuClient {
    /** The TV answered but declined this command. The session is still alive. */
    public static final class RefusedException extends IOException {
        public RefusedException(String message) { super(message); }
    }

    public static final class Device {
        public final String host, name, serial;
        public Device(String host, String name, String serial) {
            this.host = host; this.name = name; this.serial = serial;
        }
    }
    private static final Set<String> KEYS = new HashSet<>(Arrays.asList(
        "Home", "Back", "Up", "Down", "Left", "Right", "Select", "Info", "InstantReplay",
        "Rev", "Play", "Pause", "Fwd", "VolumeDown", "VolumeUp", "VolumeMute",
        "ChannelUp", "ChannelDown", "Search", "Enter", "Backspace", "FindRemote",
        "PowerOff", "PowerOn", "Power",
        "InputHDMI1", "InputHDMI2", "InputHDMI3", "InputHDMI4", "InputTuner", "InputAV1"));

    public static String validateHost(String host) {
        if (host == null) throw new IllegalArgumentException("Enter your TV's local IPv4 address.");
        String value = host.trim();
        String[] parts = value.split("\\.", -1);
        if (parts.length != 4) throw new IllegalArgumentException("Use an address like 192.168.1.20, without a port.");
        int[] octets = new int[4];
        for (int i = 0; i < 4; i++) {
            if (!parts[i].matches("0|[1-9][0-9]{0,2}")) throw new IllegalArgumentException("That IPv4 address is not valid.");
            octets[i] = Integer.parseInt(parts[i]);
            if (octets[i] > 255) throw new IllegalArgumentException("That IPv4 address is not valid.");
        }
        if (!(octets[0] == 10 || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
                || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)))
            throw new IllegalArgumentException("Use your TV's private local-network address.");
        return value;
    }

    public Device device(String host) throws Exception {
        host = validateHost(host);
        return parseDevice(host, request(host, "query/device-info", false));
    }

    static Device parseDevice(String host, byte[] bytes) throws Exception {
        XmlPullParser parser = XmlPullParserFactory.newInstance().newPullParser();
        parser.setInput(new ByteArrayInputStream(bytes), "UTF-8");
        Map<String, String> fields = new HashMap<>();
        boolean root = false;
        String field = null;
        StringBuilder content = new StringBuilder();
        for (int event = parser.nextToken(); event != XmlPullParser.END_DOCUMENT; event = parser.nextToken()) {
            if (event == XmlPullParser.DOCDECL) throw new IOException("Unexpected document type in TV response.");
            if (event == XmlPullParser.START_TAG) {
                if (!root) {
                    if (!"device-info".equals(parser.getName())) throw new IOException("This address did not return a Roku device.");
                    root = true;
                } else if (parser.getDepth() == 2) { field = parser.getName(); content.setLength(0); }
            } else if (field != null && (event == XmlPullParser.TEXT || event == XmlPullParser.CDSECT || event == XmlPullParser.ENTITY_REF)) {
                if (parser.getText() == null) throw new IOException("Unknown entity in TV response.");
                content.append(parser.getText());
            } else if (event == XmlPullParser.END_TAG && parser.getDepth() == 2 && field != null) {
                fields.put(field, content.toString().trim()); field = null;
            }
        }
        String serial = fields.getOrDefault("serial-number", "");
        if (serial.isEmpty()) throw new IOException("Could not verify this Roku device.");
        String name = fields.getOrDefault("user-device-name", "");
        if (name.isEmpty()) name = fields.getOrDefault("friendly-device-name", "");
        if (name.isEmpty()) name = fields.getOrDefault("model-name", "");
        return new Device(host, name.isEmpty() ? "Roku TV" : name, serial);
    }

    public static boolean isSupportedKey(String key) {
        return KEYS.contains(key) || isLiteral(key);
    }

    public void key(String host, String key) throws IOException {
        if (!isSupportedKey(key)) throw new IllegalArgumentException("Unsupported remote button.");
        request(validateHost(host), "keypress/" + key, true);
    }

    /** Roku text entry: Lit_ plus one character, literal or percent-encoded. */
    static boolean isLiteral(String key) {
        if (key == null || !key.startsWith("Lit_")) return false;
        String rest = key.substring(4);
        if (rest.length() == 1) { char c = rest.charAt(0); return c >= 32 && c < 127; }
        return rest.length() == 3 && rest.charAt(0) == '%' && isHex(rest.charAt(1)) && isHex(rest.charAt(2));
    }

    private static boolean isHex(char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

    private byte[] request(String host, String path, boolean post) throws IOException {
        HttpURLConnection connection = (HttpURLConnection) new URL("http://" + host + ":8060/" + path).openConnection();
        connection.setConnectTimeout(1800);
        connection.setReadTimeout(1800);
        connection.setInstanceFollowRedirects(false);
        connection.setUseCaches(false);
        try {
            if (post) {
                connection.setRequestMethod("POST");
                connection.setDoOutput(true);
                connection.setFixedLengthStreamingMode(0);
                connection.getOutputStream().close();
            }
            int code = connection.getResponseCode();
            if (code == 401 || code == 403) throw new RefusedException("TV refused that command. On the TV set Settings > System > Advanced system settings > Control by mobile apps > Network access to Permissive.");
            if (code < 200 || code >= 300) throw new IOException("TV returned error " + code + ".");
            try (InputStream in = connection.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[4096];
                int count;
                while ((count = in.read(buffer)) != -1) {
                    if (out.size() + count > 262144) throw new IOException("Unexpectedly large TV response.");
                    out.write(buffer, 0, count);
                }
                return out.toByteArray();
            }
        } catch (SocketTimeoutException | ConnectException e) {
            throw new IOException("TV is unreachable. Check that it is on and on the same Wi-Fi.", e);
        } finally { connection.disconnect(); }
    }

    public List<String> discover() throws IOException {
        Set<String> hosts = new LinkedHashSet<>();
        byte[] search = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: roku:ecp\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.setSoTimeout(450);
            DatagramPacket query = new DatagramPacket(search, search.length, InetAddress.getByName("239.255.255.250"), 1900);
            socket.send(query);
            socket.send(query);
            long deadline = System.nanoTime() + 3500000000L;
            while (System.nanoTime() < deadline && !Thread.currentThread().isInterrupted()) {
                DatagramPacket packet = new DatagramPacket(new byte[4096], 4096);
                try { socket.receive(packet); } catch (SocketTimeoutException e) { continue; }
                String text = new String(packet.getData(), 0, packet.getLength(), StandardCharsets.US_ASCII);
                if (!isRokuResponse(text)) continue;
                try { hosts.add(validateHost(packet.getAddress().getHostAddress())); } catch (IllegalArgumentException ignored) { }
                if (hosts.size() >= 24) break;
            }
        }
        return new ArrayList<>(hosts);
    }

    static boolean isRokuResponse(String text) {
        if (!text.startsWith("HTTP/1.1 200")) return false;
        for (String line : text.split("\r?\n")) {
            int split = line.indexOf(':');
            if (split > 0 && line.substring(0, split).trim().equalsIgnoreCase("st")
                    && line.substring(split + 1).trim().equalsIgnoreCase("roku:ecp")) return true;
        }
        return false;
    }
}
