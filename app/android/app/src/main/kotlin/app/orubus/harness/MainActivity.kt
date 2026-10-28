package app.orubus.harness

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.SystemClock
import android.app.usage.StorageStatsManager
import android.os.storage.StorageManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "harness/device"
    private val reqScreen = 42001
    private val reqPerms = 42002
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermResult: MethodChannel.Result? = null

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
                    "openUrl" -> {
                        try {
                            val url = call.argument<String>("url") ?: ""
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    "requestPerms" -> {
                        val wanted = (call.argument<List<String>>("perms")
                            ?: emptyList()).filter { it in DeviceReaders.REQUESTABLE }
                        if (wanted.isEmpty() || Build.VERSION.SDK_INT < 23) {
                            result.success(mapOf<String, Boolean>())
                        } else {
                            pendingPermResult = result
                            requestPermissions(wanted.toTypedArray(), reqPerms)
                        }
                    }
                    "permStates" -> result.success(DeviceReaders.permissionStates(this))
                    "openSpecial" -> {
                        try {
                            result.success(openSpecial(call.argument<String>("which") ?: ""))
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    "location" -> result.success(DeviceReaders.location(this))
                    "contacts" -> result.success(DeviceReaders.contacts(this))
                    "calls" -> result.success(DeviceReaders.callLog(this))
                    "sms" -> result.success(DeviceReaders.sms(this))
                    "sendSms" -> result.success(
                        DeviceReaders.sendSms(this,
                            call.argument<String>("to") ?: "",
                            call.argument<String>("body") ?: ""))
                    "apps" -> result.success(DeviceReaders.installedApps(this))
                    "calendar" -> result.success(DeviceReaders.calendar(this))
                    "net" -> result.success(DeviceReaders.netState(this))
                    "wifi" -> result.success(DeviceReaders.wifi(this))
                    "clipboard" -> result.success(DeviceReaders.clipboard(this))
                    "accounts" -> result.success(DeviceReaders.accounts(this))
                    "notifications" -> result.success(DeviceReaders.notifBuffer())
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

    /** Deep-link to the special-access panels. Returns true when an intent fired. */
    private fun openSpecial(which: String): Boolean {
        val i: Intent = when (which) {
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName"))
            "write_settings" -> Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS,
                Uri.parse("package:$packageName"))
            "usage" -> Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            "install" -> if (Build.VERSION.SDK_INT >= 26)
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"))
            else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"))
            "notifications" -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            "accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "battery" -> if (Build.VERSION.SDK_INT >= 23)
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"))
            "app_details" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"))
            else -> return false
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i)
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == reqPerms) {
            val r = pendingPermResult
            pendingPermResult = null
            if (r != null) {
                val out = HashMap<String, Boolean>()
                for (idx in permissions.indices) {
                    out[permissions[idx]] = grantResults[idx] == android.content.pm.PackageManager.PERMISSION_GRANTED
                }
                r.success(out)
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
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == reqScreen) {
            val r = pendingResult
            pendingResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                CaptureService.start(this, resultCode, data)
            } else {
                r?.error("DENIED", "screen capture denied by user", null)
            }
        }
    }
}
