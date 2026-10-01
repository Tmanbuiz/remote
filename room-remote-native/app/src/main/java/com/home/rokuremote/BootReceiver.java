package com.home.rokuremote;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Brings the session back after a reboot or an app update, but only if the user
 * had a TV connected and never tapped Disconnect (disconnect() clears the saved
 * host, so nothing is resumed).
 *
 * The service runs as foregroundServiceType="connectedDevice", which Android 15+
 * still permits to start from BOOT_COMPLETED.
 */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action) && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) return;
        String host = context.getSharedPreferences("session", 0).getString("host", "");
        if (host.isEmpty()) return;
        try {
            context.startForegroundService(new Intent(context, RemoteService.class).setAction(RemoteService.RESUME));
        } catch (Exception ignored) {
            // The system can still refuse a background start; the user can reopen the app.
        }
    }
}
