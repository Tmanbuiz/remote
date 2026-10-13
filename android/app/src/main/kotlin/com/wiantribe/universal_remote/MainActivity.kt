package com.wiantribe.universal_remote

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var discoveryLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.wiantribe.remote/discovery").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticast" -> {
                    if (discoveryLock?.isHeld != true) {
                        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        discoveryLock = wifi.createMulticastLock("remote-discovery").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    }
                    result.success(null)
                }
                "releaseMulticast" -> {
                    if (discoveryLock?.isHeld == true) discoveryLock?.release()
                    discoveryLock = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (discoveryLock?.isHeld == true) discoveryLock?.release()
        discoveryLock = null
        super.onDestroy()
    }
}
