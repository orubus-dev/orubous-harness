package app.orubus.harness

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/**
 * Foreground service that holds the MediaProjection (required on API 29+),
 * grabs one frame of the default display, saves it as PNG, and posts the path
 * back to MainActivity via [CaptureService.onCaptured].
 *
 * The system consent dialog appears EVERY capture — by design. No exceptions.
 */
class CaptureService : Service() {
    companion object {
        const val TAG = "CaptureService"
        const val CH_ID = "harness_capture"
        const val NOTIF_ID = 42002
        var onCaptured: ((String?) -> Unit)? = null
        private var running = false

        fun start(ctx: Context, resultCode: Int, data: Intent) {
            if (running) {
                onCaptured?.invoke(null)
                return
            }
            val i = Intent(ctx, CaptureService::class.java)
                .putExtra("code", resultCode)
                .putExtra("data", data)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i)
            } else {
                ctx.startService(i)
            }
        }
    }

    private var projection: MediaProjection? = null
    private var vdisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val code = intent?.getIntExtra("code", -1) ?: -1
        val data = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra("data", Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra("data")
        }
        if (data == null || code < 0) {
            finish(null)
            return START_NOT_STICKY
        }
        startForegroundCompat(NOTIF_ID, buildNotification(), foregroundType())
        running = true
        try {
            val pm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = pm.getMediaProjection(code, data)
            capture()
        } catch (e: Exception) {
            Log.e(TAG, "projection setup failed", e)
            finish(null)
        }
        return START_NOT_STICKY
    }

    private fun foregroundType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else 0

    private fun startForegroundCompat(id: Int, n: Notification, type: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && type != 0) {
            startForeground(id, n, type)
        } else {
            startForeground(id, n)
        }
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(CH_ID) == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(CH_ID, "Screen capture", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CH_ID) else Notification.Builder(this)
        return b.setContentTitle("Orubous Harness")
            .setContentText("Capturing one frame — you approved this")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .build()
    }

    private fun capture() {
        val metrics = resources.displayMetrics
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        val dpi = metrics.densityDpi
        reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        vdisplay = projection!!.createVirtualDisplay(
            "orubous-capture", w, h, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader!!.surface, null, Handler(Looper.getMainLooper())
        )
        // give the compositor a beat to mirror the display into the surface
        Handler(Looper.getMainLooper()).postDelayed({ grabFrame(w, h) }, 700)
    }

    private fun grabFrame(w: Int, h: Int) {
        var path: String? = null
        try {
            val img = reader!!.acquireLatestImage()
            if (img != null) {
                val plane = img.planes[0]
                val rowStride = plane.rowStride
                val pixelStride = plane.pixelStride
                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                if (rowStride == w * pixelStride) {
                    bmp.copyPixelsFromBuffer(plane.buffer)
                } else {
                    // row padding: repack row by row into a tight buffer
                    val tight = java.nio.ByteBuffer.allocateDirect(w * pixelStride * h)
                    val bb = plane.buffer
                    val row = ByteArray(w * pixelStride)
                    for (y in 0 until h) {
                        bb.position(y * rowStride)
                        bb.get(row, 0, w * pixelStride)
                        tight.put(row)
                    }
                    tight.rewind()
                    bmp.copyPixelsFromBuffer(tight)
                }
                img.close()
                val dir = File(filesDir, "screenshots").apply { mkdirs() }
                val out = File(dir, "shot_${System.currentTimeMillis()}.png")
                FileOutputStream(out).use { fos -> bmp.compress(Bitmap.CompressFormat.PNG, 90, fos) }
                path = out.absolutePath
            }
        } catch (e: Exception) {
            Log.e(TAG, "grab failed", e)
            path = null
        }
        finish(path)
    }

    private fun finish(path: String?) {
        try {
            vdisplay?.release()
        } catch (_: Exception) {}
        try {
            projection?.stop()
        } catch (_: Exception) {}
        running = false
        stopForegroundRemove()
        stopSelf()
        Handler(Looper.getMainLooper()).post { onCaptured?.invoke(path) }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundRemove() {
        stopForeground(true)
    }
}
