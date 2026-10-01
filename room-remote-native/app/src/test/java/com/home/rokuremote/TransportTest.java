package com.home.rokuremote;

import org.junit.Test;
import org.junit.Assume;
import static org.junit.Assert.*;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

public class TransportTest {
    @Test public void sendsEmptyPostAndRejectsDeniedControl() throws Exception {
        InetAddress local = null;
        for (NetworkInterface net : Collections.list(NetworkInterface.getNetworkInterfaces())) {
            for (InetAddress address : Collections.list(net.getInetAddresses()))
                if (address instanceof Inet4Address && address.isSiteLocalAddress()) local = address;
        }
        Assume.assumeNotNull(local);
        try (ServerSocket server = new ServerSocket(8060, 5, local)) {
            server.setSoTimeout(5000);
            ExecutorService worker = Executors.newSingleThreadExecutor();
            try {
                Future<String> received = worker.submit(() -> reply(server, "200 OK"));
                new RokuClient().key(local.getHostAddress(), "Home");
                String request = received.get(5, TimeUnit.SECONDS);
                assertTrue(request.startsWith("POST /keypress/Home HTTP/1.1"));
                assertTrue(request.toLowerCase(Locale.ROOT).contains("content-length: 0"));
                Future<String> denied = worker.submit(() -> reply(server, "403 Forbidden"));
                try { new RokuClient().key(local.getHostAddress(), "VolumeUp"); fail("Expected denial"); }
                catch (RokuClient.RefusedException expected) { assertTrue(expected.getMessage().contains("TV refused that command")); }
                denied.get(5, TimeUnit.SECONDS);
            } finally { worker.shutdownNow(); }
        }
    }
    private String reply(ServerSocket server, String response) throws Exception {
        try (Socket socket = server.accept()) {
            socket.setSoTimeout(5000);
            BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
            StringBuilder headers = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null && !line.isEmpty()) headers.append(line).append("\r\n");
            socket.getOutputStream().write(("HTTP/1.1 " + response + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            return headers.toString();
        }
    }
}
