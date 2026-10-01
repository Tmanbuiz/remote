package com.home.rokuremote;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.net.wifi.WifiManager;
import android.os.*;
import android.provider.Settings;
import android.speech.RecognizerIntent;
import android.view.*;
import android.widget.*;
import java.util.*;
import java.util.concurrent.*;

public class MainActivity extends Activity {
    private final int bg = Color.rgb(16, 16, 24), surface = Color.rgb(31, 31, 44), accent = Color.rgb(188, 172, 255);
    private static final long REPEAT_MS = 160;
    private static final int REQ_VOICE = 21;
    /** Roku channel ids are the same on every Roku device. */
    private static final String[][] QUICK = {{"YouTube", "837"}, {"Netflix", "12"}, {"Prime Video", "13"}};
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final List<Button> remoteButtons = new ArrayList<>();
    private final ExecutorService discovery = Executors.newSingleThreadExecutor();
    private RemoteService service;
    private boolean bound, scanning;
    private TextView tvName, status, address, badge;
    private Button disconnect, find, battery;
    private LinearLayout root;
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((RemoteService.LocalBinder) binder).service();
            service.listen(() -> refresh());
        }
        @Override public void onServiceDisconnected(ComponentName name) { service = null; refresh(); }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true); scroll.setBackgroundColor(bg);
        root = column(); root.setPadding(dp(24), dp(18), dp(24), dp(24));
        scroll.addView(root);
        setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((v, insets) -> {
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        text(root, "ROOM REMOTE", 12, accent).setLetterSpacing(.18f);
        text(root, "Your TV.\nWithin reach.", 32, Color.WHITE).setTypeface(null, Typeface.BOLD);
        text(root, "For your Roku TV", 14, Color.LTGRAY);
        space(root, 18);
        LinearLayout card = column(); card.setPadding(dp(18), dp(16), dp(18), dp(16)); card.setBackground(shape(surface, 20)); root.addView(card);
        badge = text(card, "NOT CONNECTED", 11, accent); badge.setLetterSpacing(.1f);
        tvName = text(card, "No TV selected", 21, Color.WHITE); tvName.setTypeface(null, Typeface.BOLD);
        address = text(card, "Connect your phone and TV to the same Wi-Fi", 13, Color.LTGRAY);
        status = text(card, "Choose a TV to begin", 13, Color.LTGRAY); status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        space(root, 12);
        LinearLayout connectRow = row(root);
        find = action(connectRow, "Find TVs", () -> discover());
        action(connectRow, "Enter address", () -> manual());
        space(root, 16);
        LinearLayout powerRow = row(root);
        Button power = remote(powerRow, "Power", "Power", "Power on or off");
        power.setTextColor(accent); power.setTypeface(null, Typeface.BOLD);
        space(root, 6);
        LinearLayout top = row(root);
        remote(top, "Back", "Back"); remote(top, "Home", "Home"); remote(top, "Options", "Info");
        space(root, 10);
        LinearLayout pad = column(); pad.setPadding(dp(6), dp(6), dp(6), dp(6)); pad.setBackground(shape(surface, 30)); root.addView(pad);
        LinearLayout up = row(pad); spacer(up); remoteHeld(up, "▲", "Up", "Up"); spacer(up);
        LinearLayout middle = row(pad); remoteHeld(middle, "◀", "Left", "Left");
        Button ok = remote(middle, "OK", "Select", "Select"); ok.setTextColor(bg); ok.setBackground(shape(accent, 30));
        remoteHeld(middle, "▶", "Right", "Right");
        LinearLayout down = row(pad); spacer(down); remoteHeld(down, "▼", "Down", "Down"); spacer(down);
        space(root, 12);
        LinearLayout volume = row(root);
        remoteHeld(volume, "Vol −", "VolumeDown", "Volume down"); remote(volume, "Mute", "VolumeMute"); remoteHeld(volume, "Vol +", "VolumeUp", "Volume up");
        LinearLayout playback = row(root);
        remote(playback, "Rewind", "Rev"); remote(playback, "Play / pause", "Play"); remote(playback, "Forward", "Fwd");
        LinearLayout extra = row(root);
        remote(extra, "Replay", "InstantReplay");
        Button inputs = action(extra, "Inputs", () -> inputs()); remoteButtons.add(inputs);
        Button channels = action(extra, "Channels", () -> channels()); remoteButtons.add(channels);
        LinearLayout quick = row(root);
        for (String[] pick : QUICK) {
            Button shortcut = action(quick, pick[0], () -> open(pick[1], pick[0]));
            shortcut.setTextColor(accent);
            remoteButtons.add(shortcut);
        }
        LinearLayout typeRow = row(root);
        Button voice = action(typeRow, "Voice search", () -> voiceSearch()); remoteButtons.add(voice);
        Button typing = action(typeRow, "Keyboard", () -> keyboard()); remoteButtons.add(typing);
        remote(typeRow, "Search", "Search");
        space(root, 16);
        disconnect = action(root, "Disconnect TV", () -> { if (service != null) service.disconnect(); refresh(); });
        battery = action(root, "Keep connected in the background", () -> allowBackground());
        action(root, "Connection & background help", () -> help());
        TextView foot = text(root, "No account. No ads. Just your remote.", 12, Color.GRAY); foot.setGravity(Gravity.CENTER); foot.setPadding(0, dp(14), 0, 0);
        TextView credit = text(root, "by wiaTribe", 13, accent);
        credit.setGravity(Gravity.CENTER); credit.setPadding(0, dp(2), 0, 0);
        credit.setTypeface(null, Typeface.BOLD);
        credit.setContentDescription("by wiaTribe, opens wiantribe.com");
        credit.setOnClickListener(v -> openSite());
        refresh();
    }
    @Override protected void onStart() {
        super.onStart();
        bound = bindService(new Intent(this, RemoteService.class), connection, BIND_AUTO_CREATE);
    }
    @Override protected void onStop() {
        ui.removeCallbacksAndMessages(null);
        if (service != null) service.listen(null);
        if (bound) unbindService(connection);
        bound = false; service = null;
        super.onStop();
    }
    @Override protected void onDestroy() { discovery.shutdownNow(); super.onDestroy(); }
    @Override public void onBackPressed() { moveTaskToBack(true); }

    private void refresh() {
        boolean active = service != null && service.active();
        boolean ready = service != null && service.ready();
        tvName.setText(service == null ? "No TV selected" : service.name());
        badge.setText(ready ? "CONNECTED" : active ? "CONNECTING / RETRYING" : "NOT CONNECTED");
        badge.setTextColor(ready ? Color.rgb(152, 231, 181) : accent);
        address.setText(active ? service.host() : "Connect your phone and TV to the same Wi-Fi");
        status.setText(service == null ? "Choose a TV to begin" : service.status());
        for (Button button : remoteButtons) { button.setEnabled(ready); button.setAlpha(ready ? 1f : .38f); }
        disconnect.setVisibility(active ? View.VISIBLE : View.GONE);
        battery.setVisibility(backgroundAllowed() ? View.GONE : View.VISIBLE);
    }
    /** Opens the wiaTribe site in the phone's browser. */
    private void openSite() {
        try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("https://wiantribe.com"))); }
        catch (Exception e) {
            new AlertDialog.Builder(this).setMessage("No browser is available to open wiantribe.com.")
                .setPositiveButton("OK", null).show();
        }
    }

    /** True when Android has stopped applying battery limits to this app. */
    private boolean backgroundAllowed() {
        PowerManager power = getSystemService(PowerManager.class);
        return power != null && power.isIgnoringBatteryOptimizations(getPackageName());
    }

    /** Asks Android to stop putting the app to sleep, which is what drops the session. */
    private void allowBackground() {
        if (backgroundAllowed()) {
            new AlertDialog.Builder(this).setTitle("Already allowed")
                .setMessage("Android is not limiting Room Remote. The TV session stays connected until you tap Disconnect.")
                .setPositiveButton("OK", null).show();
            return;
        }
        new AlertDialog.Builder(this).setTitle("Keep connected")
            .setMessage("Android stops background apps to save battery, which drops the TV session. Choose Allow on the next screen to keep it connected until you disconnect.")
            .setNegativeButton("Not now", null)
            .setPositiveButton("Continue", (d, w) -> {
                try {
                    startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName())));
                } catch (Exception e) {
                    try { startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)); }
                    catch (Exception ignored) {
                        startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
                    }
                }
            }).show();
    }

    private void connect(String value) {
        try { value = RokuClient.validateHost(value); }
        catch (IllegalArgumentException e) { new AlertDialog.Builder(this).setMessage(e.getMessage()).setPositiveButton("OK", null).show(); return; }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 11);
        startForegroundService(new Intent(this, RemoteService.class).setAction(RemoteService.CONNECT).putExtra("host", value));
    }
    private void manual() {
        EditText field = new EditText(this);
        field.setInputType(android.text.InputType.TYPE_CLASS_PHONE);
        field.setSingleLine(); field.setHint("192.168.1.20");
        field.setText(getSharedPreferences("remote", 0).getString("lastHost", ""));
        field.setSelectAllOnFocus(true);
        LinearLayout box = column(); box.setPadding(dp(24), dp(8), dp(24), 0);
        text(box, "On your TV: Settings → Network → About → IP address", 14, Color.LTGRAY); box.addView(field);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Connect to your TV").setView(box)
            .setNegativeButton("Cancel", null).setPositiveButton("Connect", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            try { String ip = RokuClient.validateHost(field.getText().toString()); dialog.dismiss(); connect(ip); }
            catch (IllegalArgumentException e) { field.setError(e.getMessage()); }
        }));
        dialog.show();
    }
    private void discover() {
        if (scanning) return;
        scanning = true; find.setEnabled(false); find.setText("Searching…");
        discovery.execute(() -> {
            ArrayList<RokuClient.Device> devices = new ArrayList<>();
            String failure = null;
            WifiManager.MulticastLock lock = null;
            try {
                WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
                if (wifi != null) { lock = wifi.createMulticastLock("room-remote-discovery"); lock.setReferenceCounted(false); lock.acquire(); }
                RokuClient client = new RokuClient();
                for (String host : client.discover()) {
                    if (Thread.currentThread().isInterrupted()) break;
                    try { devices.add(client.device(host)); } catch (Exception ignored) { }
                }
            } catch (Exception e) { failure = e.getMessage(); }
            finally { if (lock != null && lock.isHeld()) lock.release(); }
            final String error = failure;
            runOnUiThread(() -> {
                if (isDestroyed() || isFinishing()) return;
                scanning = false; find.setEnabled(true); find.setText("Find TVs");
                if (devices.isEmpty()) {
                    new AlertDialog.Builder(this).setTitle("No TVs found")
                        .setMessage(error == null ? "Turn your TV on and use the same Wi-Fi. Guest networks may block discovery. You can also enter the TV address manually." : "Discovery failed: " + error)
                        .setPositiveButton("Enter address", (d, w) -> manual()).setNegativeButton("Close", null).show();
                } else {
                    String[] labels = new String[devices.size()];
                    for (int i = 0; i < devices.size(); i++) labels[i] = devices.get(i).name + "\n" + devices.get(i).host;
                    new AlertDialog.Builder(this).setTitle("Choose your TV").setItems(labels, (d, which) -> connect(devices.get(which).host)).setNegativeButton("Cancel", null).show();
                }
            });
        });
    }
    /** Opens a channel by id. */
    private void open(String channelId, String label) {
        if (service != null) service.launch(channelId, label);
    }

    /** Lists everything installed on the TV and opens whichever one is tapped. */
    private void channels() {
        if (service == null) return;
        status.setText("Loading channels…");
        service.channels(list -> {
            if (isDestroyed() || isFinishing()) return;
            if (list == null || list.isEmpty()) {
                new AlertDialog.Builder(this).setTitle("No channels")
                    .setMessage("The TV did not list any channels.").setPositiveButton("OK", null).show();
                return;
            }
            String[] labels = new String[list.size()];
            for (int i = 0; i < list.size(); i++) {
                RokuSession.Channel channel = list.get(i);
                labels[i] = channel.input ? channel.name + "  ·  input" : channel.name;
            }
            new AlertDialog.Builder(this).setTitle("Open on TV")
                .setItems(labels, (d, which) -> open(list.get(which).id, list.get(which).name))
                .setNegativeButton("Cancel", null).show();
        }, error -> {
            if (isDestroyed() || isFinishing()) return;
            new AlertDialog.Builder(this).setTitle("Could not load channels")
                .setMessage(error).setPositiveButton("OK", null).show();
        });
    }

    private void inputs() {
        String[] labels = {"HDMI 1", "HDMI 2", "HDMI 3", "HDMI 4", "Antenna TV"};
        String[] keys = {"InputHDMI1", "InputHDMI2", "InputHDMI3", "InputHDMI4", "InputTuner"};
        new AlertDialog.Builder(this).setTitle("Choose input").setItems(labels, (d, i) -> send(keys[i], labels[i])).setNegativeButton("Cancel", null).show();
    }
    /**
     * Speaks a search term onto the TV. The system recognizer owns the microphone
     * and its permission, so this app never records audio itself.
     */
    private void voiceSearch() {
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PROMPT, "Say what to search for on the TV")
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
        try { startActivityForResult(intent, REQ_VOICE); }
        catch (ActivityNotFoundException e) {
            new AlertDialog.Builder(this).setTitle("Voice input unavailable")
                .setMessage("No speech recognizer is installed on this phone. Use Keyboard to type instead.")
                .setPositiveButton("OK", null).show();
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != REQ_VOICE || result != RESULT_OK || data == null) return;
        ArrayList<String> heard = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS);
        if (heard == null || heard.isEmpty()) return;
        String spoken = heard.get(0).trim();
        if (spoken.isEmpty()) return;
        if (service != null && service.ready()) service.type(spoken);
        else status.setText("Heard \"" + spoken + "\" but no TV is connected.");
    }

    /** Types into whatever field the TV has focused, e.g. a search box. */
    private void keyboard() {
        EditText field = new EditText(this);
        field.setSingleLine(); field.setHint("Type here");
        field.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_DONE);
        LinearLayout box = column(); box.setPadding(dp(24), dp(8), dp(24), 0);
        text(box, "Goes to the box your TV has selected, one letter at a time. Open a search field on the TV first.", 14, Color.LTGRAY);
        box.addView(field);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Keyboard / search").setView(box)
            .setNegativeButton("Close", null)
            .setNeutralButton("Backspace", (d, w) -> send("Backspace", "Backspace"))
            .setPositiveButton("Send", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String value = field.getText().toString();
            if (value.isEmpty()) { field.setError("Type something first."); return; }
            if (service != null) service.type(value);
            field.setText("");
            dialog.dismiss();
        }));
        dialog.show();
    }

    private void send(String key, String label) {
        if (service != null) service.key(key, label);
    }
    private void help() {
        new AlertDialog.Builder(this).setTitle("Room Remote")
            .setMessage("CONNECT\nUse the same Wi-Fi as your TV. Room Remote controls it over Roku's authenticated channel, so you do not need to change any TV setting.\n\nSTAY CONNECTED\nThe session stays active when you switch apps, press Back, lock your phone, swipe the app out of recents, or restart the phone. It reconnects by itself if Wi-Fi drops. Tap \"Keep connected in the background\" once so Android stops putting the app to sleep.\n\nSTOP\nIt stays connected until you tap Disconnect, here or on the notification. Force-stopping also stops it.\n\nBUTTONS\nHold the arrows or volume to repeat. Keyboard / search types into the box your TV has selected. Power turns the TV on or off.\n\nABOUT\nRoom Remote by wiaTribe · wiantribe.com\nNot affiliated with, endorsed by, or sponsored by Roku.")
            .setPositiveButton("Got it", null)
            .setNeutralButton("wiantribe.com", (d, w) -> openSite()).show();
    }
    private LinearLayout column() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); return layout; }
    private LinearLayout row(LinearLayout parent) { LinearLayout layout = new LinearLayout(this); layout.setGravity(Gravity.CENTER); parent.addView(layout, new LinearLayout.LayoutParams(-1, -2)); return layout; }
    private TextView text(LinearLayout parent, String value, int size, int color) { TextView text = new TextView(this); text.setText(value); text.setTextSize(size); text.setTextColor(color); text.setPadding(0, dp(4), 0, dp(4)); parent.addView(text); return text; }
    private void space(LinearLayout parent, int height) { parent.addView(new View(this), new LinearLayout.LayoutParams(1, dp(height))); }
    private void spacer(LinearLayout parent) { parent.addView(new View(this), new LinearLayout.LayoutParams(0, dp(64), 1)); }
    private Button action(LinearLayout parent, String label, Runnable runnable) {
        Button button = new Button(this); button.setText(label); button.setTextSize(13); button.setAllCaps(false);
        button.setTextColor(Color.WHITE); button.setBackground(shape(surface, 16)); button.setPadding(dp(6), dp(4), dp(6), dp(4));
        button.setMinWidth(0); button.setMinimumWidth(0); button.setMinHeight(dp(58));
        LinearLayout.LayoutParams params = parent.getOrientation() == LinearLayout.HORIZONTAL ? new LinearLayout.LayoutParams(0, dp(64), 1) : new LinearLayout.LayoutParams(-1, dp(58));
        params.setMargins(dp(3), dp(4), dp(3), dp(4)); parent.addView(button, params);
        button.setOnClickListener(v -> { v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); runnable.run(); }); return button;
    }
    /** Like remote(), but holding the button repeats the key so you can scroll a long list. */
    private Button remoteHeld(LinearLayout parent, String label, String key, String description) {
        Button button = remote(parent, label, key, description);
        final Runnable[] tick = new Runnable[1];
        tick[0] = () -> { send(key, description); ui.postDelayed(tick[0], REPEAT_MS); };
        // Repeat starts on long-press, never on touch-down: consuming the down event
        // would send a key when you only meant to scroll the page.
        button.setOnLongClickListener(v -> {
            if (!v.isEnabled()) return false;
            v.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
            send(key, description);
            ui.postDelayed(tick[0], REPEAT_MS);
            return true;
        });
        button.setOnTouchListener((v, event) -> {
            int action = event.getActionMasked();
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) ui.removeCallbacks(tick[0]);
            return false;
        });
        return button;
    }

    private Button remote(LinearLayout parent, String label, String key) { return remote(parent, label, key, label); }
    private Button remote(LinearLayout parent, String label, String key, String description) { Button button = action(parent, label, () -> send(key, description)); button.setContentDescription(description); remoteButtons.add(button); return button; }
    private GradientDrawable shape(int color, int radius) { GradientDrawable drawable = new GradientDrawable(); drawable.setColor(color); drawable.setCornerRadius(dp(radius)); return drawable; }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
