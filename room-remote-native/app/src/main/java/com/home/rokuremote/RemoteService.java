package com.home.rokuremote;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.os.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Owns the session independently of the Activity and retries only read-only health checks. */
public class RemoteService extends Service {
    public static final String CONNECT = "com.home.rokuremote.CONNECT";
    public static final String DISCONNECT = "com.home.rokuremote.DISCONNECT";
    public static final String RESUME = "com.home.rokuremote.RESUME";
    private static final String CHANNEL = "tv_connection";
    private static final int NOTIFICATION = 7;
    public interface Listener { void changed(); }
    public final class LocalBinder extends Binder { public RemoteService service() { return RemoteService.this; } }
    private final LocalBinder binder = new LocalBinder();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private final AtomicInteger pending = new AtomicInteger();
    private final RokuClient client = new RokuClient();
    private final RokuSession session = new RokuSession();
    private ScheduledFuture<?> heartbeat;
    private Listener listener;
    private volatile int generation;
    private volatile boolean active;
    private volatile boolean reachable;
    private volatile String host = "";
    private volatile String expectedSerial = "";
    private RokuClient.Device device;
    private String status = "Choose a TV to begin";

    @Override public void onCreate() {
        super.onCreate();
        NotificationChannel channel = new NotificationChannel(CHANNEL, "TV connection", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Keeps the remote session available while you use other apps.");
        getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }
    @Override public IBinder onBind(Intent intent) { return binder; }
    public void listen(Listener value) { listener = value; if (value != null) value.changed(); }
    public String status() { return status; }
    public String name() { return device == null ? (host.isEmpty() ? "No TV selected" : host) : device.name; }
    public String host() { return host; }
    public boolean active() { return active; }
    public boolean ready() { return active && reachable; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && DISCONNECT.equals(intent.getAction())) { disconnect(); return START_NOT_STICKY; }
        // A resume (boot, app update, or the system restarting a sticky service) has no
        // host extra and reuses the saved session; an explicit connect carries the host.
        String target = intent == null ? null : intent.getStringExtra("host");
        boolean resumed = target == null || target.isEmpty();
        if (resumed) target = getSharedPreferences("session", 0).getString("host", "");
        if (target == null || target.isEmpty()) { stopSelf(); return START_NOT_STICKY; }
        try { target = RokuClient.validateHost(target); }
        catch (IllegalArgumentException e) { disconnect(); return START_NOT_STICKY; }
        generation++;
        int token = generation;
        session.close();
        active = true; reachable = false; host = target; device = null;
        expectedSerial = resumed ? getSharedPreferences("session", 0).getString("serial", "") : "";
        getSharedPreferences("session", 0).edit().putString("host", host).putString("serial", expectedSerial).apply();
        status = "Connecting…";
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(NOTIFICATION, notification());
        if (heartbeat != null) heartbeat.cancel(false);
        heartbeat = worker.scheduleWithFixedDelay(() -> check(token), 0, 30, TimeUnit.SECONDS);
        changed();
        return START_STICKY;
    }

    private void check(int token) {
        if (!active || token != generation) return;
        try {
            RokuClient.Device found = client.device(host);
            String serial = expectedSerial;
            if (!serial.isEmpty() && !serial.equals(found.serial)) throw new java.io.IOException("A different TV is using this address. Disconnect and select your TV again.");
            main.post(() -> {
                if (!active || token != generation) return;
                device = found; expectedSerial = found.serial; reachable = true;
                getSharedPreferences("session", 0).edit().putString("serial", found.serial).apply();
                getSharedPreferences("remote", 0).edit().putString("lastHost", host).apply();
                status = "Connected · stays active in the background";
                changed();
            });
            // Keep the control channel warm so the first button press is instant and a
            // dropped Wi-Fi connection heals on its own rather than on the next press.
            if (!session.isOpen()) {
                try { session.open(host); } catch (Exception ignored) { }
            }
        } catch (Exception e) { session.close(); report(token, "Waiting for TV · " + message(e), false); }
    }

    public void key(String key, String label) {
        if (!ready()) return;
        if (pending.incrementAndGet() > 10) { pending.decrementAndGet(); return; }
        final int token = generation;
        final String address = host;
        worker.execute(() -> {
            try {
                if (!active || token != generation || !reachable) return;
                sendKey(address, key);
                report(token, label + " sent · connection stays active", true);
            } catch (RokuClient.RefusedException e) { report(token, message(e), true); }
            catch (Exception e) { report(token, message(e), false); }
            finally { pending.decrementAndGet(); }
        });
    }

    /** Opens a channel or TV input by id. */
    public void launch(String channelId, String label) {
        if (!ready()) return;
        final int token = generation;
        final String address = host;
        worker.execute(() -> {
            try {
                run(address, s -> s.launch(channelId));
                report(token, label + " opened · connection stays active", true);
            } catch (RokuClient.RefusedException e) { report(token, message(e), true); }
            catch (Exception e) { report(token, message(e), false); }
        });
    }

    /** Fetches the channel list off the main thread and hands it back on it. */
    public void channels(java.util.function.Consumer<java.util.List<RokuSession.Channel>> onList,
                         java.util.function.Consumer<String> onError) {
        if (!ready()) { main.post(() -> onError.accept("Connect to your TV first.")); return; }
        final String address = host;
        worker.execute(() -> {
            try {
                java.util.List<RokuSession.Channel>[] box = new java.util.List[1];
                run(address, s -> box[0] = s.channels());
                main.post(() -> onList.accept(box[0]));
            } catch (Exception e) { main.post(() -> onError.accept(message(e))); }
        });
    }

    private interface SessionCall { void run(RokuSession session) throws java.io.IOException; }

    /** Runs one call on the ECP-2 channel, reopening it once if it dropped. */
    private void run(String address, SessionCall body) throws java.io.IOException {
        try {
            if (!session.isOpen()) session.open(address);
            body.run(session);
        } catch (RokuClient.RefusedException e) {
            throw e;
        } catch (java.io.IOException first) {
            session.close();
            session.open(address);
            body.run(session);
        }
    }

    private void sendKey(String address, String key) throws java.io.IOException {
        run(address, s -> s.press(key));
    }

    /**
     * Types a string into whatever field the TV has focused, one Lit_ key per
     * character. Runs as a single worker task so a long string cannot be
     * truncated by the per-button in-flight cap.
     */
    public void type(String text) {
        if (!ready() || text == null || text.isEmpty()) return;
        final int token = generation;
        final String address = host;
        final String value = text;
        worker.execute(() -> {
            int sent = 0;
            for (int i = 0; i < value.length(); i++) {
                if (!active || token != generation || !reachable) return;
                String key = literalKey(value.charAt(i));
                if (key == null) continue;
                try { sendKey(address, key); sent++; }
                catch (RokuClient.RefusedException e) { report(token, message(e), true); return; }
                catch (Exception e) { report(token, message(e), false); return; }
            }
            report(token, sent + (sent == 1 ? " character" : " characters") + " sent to the TV", true);
        });
    }

    /**
     * Maps one character to a Roku Lit_ key. ECP-2 carries the raw character:
     * percent-encoding is an HTTP-URL convention and the TV answers 400 to it.
     */
    static String literalKey(char c) {
        if (c >= 32 && c < 127) return "Lit_" + c;
        return null;
    }

    private void report(int token, String message, boolean online) {
        main.post(() -> {
            if (!active || token != generation) return;
            reachable = online; status = message; changed();
        });
    }
    private static String message(Exception e) {
        return e.getMessage() == null ? "Unable to reach TV. Check your Wi-Fi." : e.getMessage();
    }
    private void changed() {
        if (active) getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
        if (listener != null) listener.changed();
    }
    private Notification notification() {
        PendingIntent open = PendingIntent.getActivity(this, 0,
            new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        PendingIntent disconnect = PendingIntent.getService(this, 1,
            new Intent(this, RemoteService.class).setAction(DISCONNECT), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Room Remote · " + name())
            .setContentText(reachable ? "Remote ready. Tap to open." : "Waiting for your TV. Retrying automatically.")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(new Notification.Action.Builder(null, "Disconnect", disconnect).build()).build();
    }
    public void disconnect() {
        active = false; reachable = false; generation++;
        session.close();
        if (heartbeat != null) heartbeat.cancel(false);
        getSharedPreferences("session", 0).edit().clear().apply();
        host = ""; device = null; expectedSerial = ""; status = "Disconnected";
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
        changed();
    }
    @Override public void onDestroy() {
        active = false; generation++;
        session.close();
        getSharedPreferences("session", 0).edit().clear().apply();
        worker.shutdownNow();
        main.removeCallbacksAndMessages(null);
        listener = null;
        super.onDestroy();
    }
}
