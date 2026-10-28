package app.orubus.harness

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground keep-alive for the bridge engine.
 *
 * The Dart bridge isolate lives inside the Activity process. When the app is
 * backgrounded on modern Android the process gets cached/frozen and the ntfy
 * stream dies — the operator sees timeouts (observed on Android 15, 2026-10-28).
 * A started foreground service raises the process priority so the whole
 * process, Dart isolate included, keeps running while backgrounded or with the
 * screen off. The engine itself is untouched: this service only holds the
 * process up and shows the persistent "Orubus link live" notification.
 *
 * Uses the `specialUse` FGS type: no 6-hour cap (unlike dataSync on 15+), and
 * we are sideloaded — no Play declaration review applies.
 */
class BridgeService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHAN, "Orubus link",
                    NotificationManager.IMPORTANCE_LOW))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = if (launch != null)
            PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE)
        else null
        val b: Notification.Builder = if (Build.VERSION.SDK_INT >= 26)
            Notification.Builder(this, CHAN)
        else
            @Suppress("DEPRECATION") Notification.Builder(this)
        b.setContentTitle("Orubus link live")
            .setContentText("bridge is listening — tap to open")
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setOngoing(true)
        if (pi != null) b.setContentIntent(pi)
        val n = b.build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
        // If the process dies the Dart engine dies with it; restarting this
        // service alone would only show a pointless notification.
        return START_NOT_STICKY
    }

    companion object {
        private const val CHAN = "orubus_link"
        private const val NOTIF_ID = 43001

        fun start(c: Context) {
            val i = Intent(c, BridgeService::class.java)
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
        }

        fun stop(c: Context) {
            c.stopService(Intent(c, BridgeService::class.java))
        }
    }
}
