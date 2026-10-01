package com.home.rokuremote;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;

/**
 * Persistent Roku ECP-2 control channel: a hand-rolled RFC 6455 WebSocket to
 * ws://host:8060/ecp-session plus the authenticated key-press protocol.
 *
 * This is the channel the official Roku app uses. Unlike plain HTTP /keypress,
 * the TV honors navigation over it without changing "Control by mobile apps".
 * Local network only; the host is validated by {@link RokuClient#validateHost}.
 */
public final class RokuSession implements Closeable {
    /** Derived once from Roku's published ECP-2 secret; see RokuSessionTest for the vector. */
    static final byte[] AUTH_KEY = "F3A278B8-1C6F-44A9-9D89-F1979CA4C6F1".getBytes(StandardCharsets.UTF_8);
    private static final String WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    private final SecureRandom random = new SecureRandom();
    private final ConcurrentHashMap<String, CompletableFuture<String>> pending = new ConcurrentHashMap<>();
    private int requestId = 1;
    private Socket socket;
    private InputStream in;
    private OutputStream out;
    private Thread reader;
    private volatile boolean open;

    public boolean isOpen() { return open; }

    /** Computes the ECP-2 challenge response: base64(SHA1(challenge + AUTH_KEY)). */
    static String authResponse(String challenge) throws IOException {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            md.update(challenge.getBytes(StandardCharsets.UTF_8));
            md.update(AUTH_KEY);
            return Base64.getEncoder().encodeToString(md.digest());
        } catch (Exception e) { throw new IOException("Cannot compute TV authentication.", e); }
    }

    /** Opens and authenticates the session. Blocking; throws on any failure. */
    public synchronized void open(String host) throws IOException {
        close();
        host = RokuClient.validateHost(host);
        Socket s = new Socket();
        s.connect(new InetSocketAddress(host, 8060), 2500);
        s.setTcpNoDelay(true);
        s.setSoTimeout(4000);
        try {
            InputStream input = new BufferedInputStream(s.getInputStream());
            OutputStream output = s.getOutputStream();
            handshake(host, input, output);
            String challenge = jsonField(readTextMessage(input), "param-challenge");
            if (challenge == null) throw new IOException("TV did not start authentication.");
            writeText(output, "{\"request\":\"authenticate\",\"request-id\":\"" + (requestId++)
                + "\",\"param-response\":\"" + authResponse(challenge)
                + "\",\"param-client-friendly-name\":\"Room Remote\",\"param-has-microphone\":\"false\"}");
            String reply = readTextMessage(input);
            if (!"200".equals(jsonField(reply, "status")))
                throw new IOException("TV declined the remote session.");
            this.socket = s; this.in = input; this.out = output;
            s.setSoTimeout(0);
            open = true;
            reader = new Thread(this::readLoop, "roku-ecp2");
            reader.setDaemon(true);
            reader.start();
        } catch (IOException e) {
            try { s.close(); } catch (IOException ignored) { }
            throw e;
        }
    }

    /** One channel (or TV input) the TV can switch to. */
    public static final class Channel {
        public final String id, name;
        public final boolean input;
        Channel(String id, String name, boolean input) { this.id = id; this.name = name; this.input = input; }
        @Override public String toString() { return name; }
    }

    /** Sends one request, waits for the matching reply, and returns it. */
    private String call(String request, String fields, int timeoutSeconds, String failure) throws IOException {
        OutputStream output = out;
        if (!open || output == null || socket == null) throw new IOException("Remote session is not open.");
        String id = String.valueOf(nextId());
        CompletableFuture<String> ack = new CompletableFuture<>();
        pending.put(id, ack);
        try {
            synchronized (this) {
                writeText(output, "{\"request\":\"" + request + "\"" + fields + ",\"request-id\":\"" + id + "\"}");
            }
            try { return ack.get(timeoutSeconds, TimeUnit.SECONDS); }
            catch (TimeoutException e) { throw new IOException(failure); }
            catch (ExecutionException e) { throw new IOException("Remote session dropped."); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new IOException("Interrupted."); }
        } finally { pending.remove(id); }
    }

    /** Sends a remote key and waits for the TV to acknowledge it. */
    public void press(String key) throws IOException {
        if (!RokuClient.isSupportedKey(key)) throw new IllegalArgumentException("Unsupported remote button.");
        String reply = call("key-press", ",\"param-key\":\"" + jsonEscape(key) + "\"", 3, "TV did not respond to the button.");
        if (!accepted(jsonField(reply, "status"))) throw new RokuClient.RefusedException("TV refused that button.");
    }

    /** Opens a channel or TV input by its Roku id. */
    public void launch(String channelId) throws IOException {
        if (!isChannelId(channelId)) throw new IllegalArgumentException("Unsupported channel.");
        String reply = call("launch", ",\"param-channel-id\":\"" + channelId + "\"", 5, "TV did not respond to the channel.");
        if (!accepted(jsonField(reply, "status"))) throw new RokuClient.RefusedException("That channel is not installed on this TV.");
    }

    /** Lists the channels and inputs installed on the TV. */
    public List<Channel> channels() throws IOException {
        String reply = call("query-apps", "", 6, "TV did not send its channel list.");
        if (!accepted(jsonField(reply, "status"))) throw new IOException("TV would not share its channel list.");
        String encoded = jsonField(reply, "content-data");
        if (encoded == null) throw new IOException("TV sent an empty channel list.");
        byte[] xml;
        try { xml = Base64.getMimeDecoder().decode(encoded); }
        catch (IllegalArgumentException e) { throw new IOException("TV sent an unreadable channel list."); }
        if (xml.length > 262144) throw new IOException("Channel list is too large.");
        return parseChannels(xml);
    }

    /** Roku channel ids are digits; TV inputs look like "tvinput.hdmi1". */
    static boolean isChannelId(String id) {
        if (id == null || id.isEmpty() || id.length() > 40) return false;
        for (int i = 0; i < id.length(); i++) {
            char c = id.charAt(i);
            if (!(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '.' || c == '_' || c == '-')) return false;
        }
        return true;
    }

    /** Parses the &lt;apps&gt; document the TV returns, rejecting anything unexpected. */
    static List<Channel> parseChannels(byte[] xml) throws IOException {
        List<Channel> found = new ArrayList<>();
        try {
            org.xmlpull.v1.XmlPullParser parser = org.xmlpull.v1.XmlPullParserFactory.newInstance().newPullParser();
            parser.setInput(new ByteArrayInputStream(xml), "UTF-8");
            String id = null, type = null;
            StringBuilder name = new StringBuilder();
            boolean inApp = false, root = false;
            for (int event = parser.nextToken(); event != org.xmlpull.v1.XmlPullParser.END_DOCUMENT; event = parser.nextToken()) {
                if (event == org.xmlpull.v1.XmlPullParser.DOCDECL) throw new IOException("Unexpected document type.");
                if (event == org.xmlpull.v1.XmlPullParser.START_TAG && !root) {
                    if (!"apps".equals(parser.getName())) throw new IOException("This is not a Roku channel list.");
                    root = true;
                    continue;
                }
                if (event == org.xmlpull.v1.XmlPullParser.START_TAG && "app".equals(parser.getName())) {
                    id = parser.getAttributeValue(null, "id");
                    type = parser.getAttributeValue(null, "type");
                    name.setLength(0);
                    inApp = true;
                } else if (inApp && (event == org.xmlpull.v1.XmlPullParser.TEXT || event == org.xmlpull.v1.XmlPullParser.CDSECT
                        || event == org.xmlpull.v1.XmlPullParser.ENTITY_REF)) {
                    if (parser.getText() != null) name.append(parser.getText());
                } else if (event == org.xmlpull.v1.XmlPullParser.END_TAG && "app".equals(parser.getName())) {
                    String label = name.toString().replace(' ', ' ').trim();
                    if (isChannelId(id) && !label.isEmpty()) found.add(new Channel(id, label, "tvin".equals(type)));
                    inApp = false; id = null; type = null;
                    if (found.size() >= 200) break;
                }
            }
            if (!root) throw new IOException("This is not a Roku channel list.");
            if (inApp) throw new IOException("The channel list was cut short.");
        } catch (IOException e) { throw e;
        } catch (Exception e) { throw new IOException("Could not read the channel list."); }
        return found;
    }

    private synchronized int nextId() { return requestId++; }

    private void readLoop() {
        try {
            while (open) {
                Frame frame = readFrame(in);
                if (frame == null || frame.opcode == 0x8) break;          // close
                if (frame.opcode == 0x9) { synchronized (this) { writeFrame(out, 0xA, frame.payload); } continue; } // ping -> pong
                if (frame.opcode != 0x1 && frame.opcode != 0x0) continue; // only care about text
                String msg = new String(frame.payload, StandardCharsets.UTF_8);
                String id = jsonField(msg, "response-id");
                if (id != null) {
                    CompletableFuture<String> ack = pending.remove(id);
                    if (ack != null) ack.complete(msg);
                }
            }
        } catch (IOException ignored) {
        } finally { fail(); }
    }

    private void fail() {
        open = false;
        for (CompletableFuture<String> ack : pending.values()) ack.completeExceptionally(new IOException("Session closed."));
        pending.clear();
    }

    @Override public synchronized void close() {
        open = false;
        Socket s = socket; socket = null; in = null; out = null;
        if (s != null) try { s.close(); } catch (IOException ignored) { }
        fail();
    }

    // ---- RFC 6455 framing (client side: outgoing frames are masked) ----

    private void handshake(String host, InputStream input, OutputStream output) throws IOException {
        byte[] nonce = new byte[16]; random.nextBytes(nonce);
        String key = Base64.getEncoder().encodeToString(nonce);
        String request = "GET /ecp-session HTTP/1.1\r\n"
            + "Host: " + host + ":8060\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: " + key + "\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: ecp-2\r\n\r\n";
        output.write(request.getBytes(StandardCharsets.US_ASCII));
        output.flush();
        String statusLine = readLine(input);
        if (statusLine == null || !statusLine.startsWith("HTTP/1.1 101"))
            throw new IOException("TV did not accept the remote channel.");
        String accept = null, line;
        while ((line = readLine(input)) != null && !line.isEmpty()) {
            int c = line.indexOf(':');
            if (c > 0 && line.substring(0, c).trim().equalsIgnoreCase("sec-websocket-accept"))
                accept = line.substring(c + 1).trim();
        }
        if (!expectedAccept(key).equals(accept)) throw new IOException("TV failed the remote handshake.");
    }

    static String expectedAccept(String key) throws IOException {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            md.update((key + WS_GUID).getBytes(StandardCharsets.US_ASCII));
            return Base64.getEncoder().encodeToString(md.digest());
        } catch (Exception e) { throw new IOException(e); }
    }

    private static String readLine(InputStream input) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int b; boolean any = false;
        while ((b = input.read()) != -1) {
            any = true;
            if (b == '\n') break;
            if (b != '\r') buf.write(b);
        }
        if (!any && buf.size() == 0) return null;
        return buf.toString("US-ASCII");
    }

    private void writeText(OutputStream output, String text) throws IOException {
        writeFrame(output, 0x1, text.getBytes(StandardCharsets.UTF_8));
    }

    /** Builds one masked client frame. Static and side-effect free for testing. */
    static byte[] buildFrame(int opcode, byte[] payload, byte[] mask) {
        ByteArrayOutputStream f = new ByteArrayOutputStream();
        f.write(0x80 | (opcode & 0x0F));
        int len = payload.length;
        if (len < 126) f.write(0x80 | len);
        else if (len < 65536) { f.write(0x80 | 126); f.write((len >> 8) & 0xFF); f.write(len & 0xFF); }
        else {
            f.write(0x80 | 127);
            for (int i = 7; i >= 0; i--) f.write((int) (((long) len >> (8 * i)) & 0xFF));
        }
        f.write(mask, 0, 4);
        for (int i = 0; i < len; i++) f.write(payload[i] ^ mask[i & 3]);
        return f.toByteArray();
    }

    private void writeFrame(OutputStream output, int opcode, byte[] payload) throws IOException {
        byte[] mask = new byte[4]; random.nextBytes(mask);
        output.write(buildFrame(opcode, payload, mask));
        output.flush();
    }

    static final class Frame { int opcode; byte[] payload; }

    /** Reads one frame (handles server frames, which are not masked). */
    static Frame readFrame(InputStream input) throws IOException {
        int b0 = input.read(); if (b0 == -1) return null;
        int b1 = input.read(); if (b1 == -1) return null;
        Frame frame = new Frame();
        frame.opcode = b0 & 0x0F;
        boolean masked = (b1 & 0x80) != 0;
        long len = b1 & 0x7F;
        if (len == 126) len = (readByte(input) << 8) | readByte(input);
        else if (len == 127) { len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | readByte(input); }
        if (len < 0 || len > 262144) throw new IOException("Oversized TV frame.");
        byte[] mask = new byte[4];
        if (masked) readFully(input, mask, 4);
        byte[] payload = new byte[(int) len];
        readFully(input, payload, (int) len);
        if (masked) for (int i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
        frame.payload = payload;
        return frame;
    }

    private String readTextMessage(InputStream input) throws IOException {
        Frame frame = readFrame(input);
        if (frame == null) throw new IOException("TV closed the channel.");
        return new String(frame.payload, StandardCharsets.UTF_8);
    }

    private static int readByte(InputStream input) throws IOException {
        int b = input.read(); if (b == -1) throw new EOFException(); return b;
    }
    private static void readFully(InputStream input, byte[] dst, int len) throws IOException {
        int off = 0; while (off < len) { int r = input.read(dst, off, len - off); if (r == -1) throw new EOFException(); off += r; }
    }

    /**
     * True when the TV accepted a request. Power keys answer 202 Accepted rather
     * than 200 OK, so anything in the 2xx range counts as success.
     */
    static boolean accepted(String status) {
        if (status == null || status.length() != 3) return false;
        try { int code = Integer.parseInt(status); return code >= 200 && code < 300; }
        catch (NumberFormatException e) { return false; }
    }

    /** Escapes a value for a JSON string, so a typed " or \ cannot break the payload. */
    static String jsonEscape(String value) {
        StringBuilder b = new StringBuilder(value.length() + 4);
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
            else b.append(c);
        }
        return b.toString();
    }

    /** Minimal flat-JSON string field reader (values are simple ASCII). */
    static String jsonField(String json, String key) {
        String pat = "\"" + key + "\"";
        int i = json.indexOf(pat); if (i < 0) return null;
        int c = json.indexOf(':', i + pat.length()); if (c < 0) return null;
        int q1 = json.indexOf('"', c + 1); if (q1 < 0) return null;
        int q2 = json.indexOf('"', q1 + 1); if (q2 < 0) return null;
        return json.substring(q1 + 1, q2);
    }
}
