package dev.orubous.harness

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.BatteryManager
import android.os.Build
import android.os.SystemClock
import android.app.usage.StorageStatsManager
import android.os.storage.StorageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "harness/device"
    private val reqScreen = 42001
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInfo" -> result.success(deviceInfo())
                    "takeScreenshot" -> {
                        pendingResult = result
                        startProjection()
                    }
                    else -> result.notImplemented()
                }
            }
        CaptureService.onCaptured = { path ->
            val r = pendingResult
            pendingResult = null
            if (r != null) {
                if (path != null) r.success(path)
                else r.error("CAPTURE_FAILED", "projection capture returned null", null)
            }
        }
    }

    private fun deviceInfo(): Map<String, Any> {
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val battery = try {
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (e: Exception) {
            -1
        }
        val storage = try {
            val sm = getSystemService(Context.STORAGE_STATS_SERVICE) as StorageStatsManager
            val uuid = StorageManager.UUID_DEFAULT
            val total = sm.getTotalBytes(uuid)
            val free = sm.getFreeBytes(uuid)
            mapOf("total" to total, "free" to free)
        } catch (e: Exception) {
            mapOf<String, Long>()
        }
        val m = resources.displayMetrics
        return mapOf(
            "model" to Build.MODEL,
            "brand" to Build.BRAND,
            "android" to (Build.VERSION.RELEASE ?: "?"),
            "sdk" to Build.VERSION.SDK_INT,
            "battery" to battery,
            "storage_total" to (storage["total"] ?: -1L),
            "storage_free" to (storage["free"] ?: -1L),
            "display" to "${m.widthPixels}x${m.heightPixels} @${m.densityDpi}dpi",
            "uptime_s" to SystemClock.elapsedRealtime() / 1000,
            "host" to (Build.HOST ?: "?"),
        )
    }

    private fun startProjection() {
        val pm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as android.media.projection.MediaProjectionManager
        startActivityForResult(pm.createScreenCaptureIntent(), reqScreen)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == reqScreen) {
            val r = pendingResult
            pendingResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                CaptureService.start(this, resultCode, data)
            } else {
                r?.error("DENIED", "screen capture denied by user", null)
            }
            return true
        }
        return super.onActivityResult(requestCode, resultCode, data)
    }
}
