package com.wiantribe.universal_remote

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingStart: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methods = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        // The notification's "Turn off" button asks Dart to close the microphone.
        MicMonitorService.onStopRequested = {
            runOnUiThread { methods.invokeMethod("stopRequested", null) }
        }

        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> startMonitor(call.argument<String>("text"), result)
                "update" -> {
                    MicMonitorService.update(call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, MicMonitorService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Raises the notification, answering true only once it can actually be seen.
     *
     * Android 13 and later hide a foreground service's notification until the
     * user grants POST_NOTIFICATIONS, and a user can also switch the app's
     * notifications off outright. Either way the monitor must not run, so the
     * answer is false and Dart declines to open the microphone.
     */
    private fun startMonitor(text: String?, result: MethodChannel.Result) {
        val begin = {
            val manager = getSystemService(NotificationManager::class.java)
            if (!manager.areNotificationsEnabled()) {
                result.success(false)
            } else {
                startForegroundService(
                    Intent(this, MicMonitorService::class.java)
                        .putExtra(MicMonitorService.EXTRA_TEXT, text),
                )
                result.success(true)
            }
        }
        val needsAsk = Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        if (needsAsk) {
            pendingStart = begin
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        } else {
            begin()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        // Whatever the answer, areNotificationsEnabled() in the continuation is
        // the authority on whether the notification can be seen.
        pendingStart?.invoke()
        pendingStart = null
    }

    override fun onDestroy() {
        MicMonitorService.onStopRequested = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "com.wiantribe.universal_remote/mic_service"
        private const val REQUEST_NOTIFICATIONS = 4101
    }
}
