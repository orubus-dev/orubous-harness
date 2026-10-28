package app.orubus.harness

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Passive notification capture. NOTHING is collected until the user flips
 * "Notification access" for this app in system settings (Device Access screen
 * deep-links there). Keeps the last 50 notifications in memory only — no disk,
 * no telemetry; they exist solely to be read over the operator bridge.
 */
class NotifListener : NotificationListenerService() {

    companion object {
        const val MAX = 50
        val buffer = ArrayDeque<String>()

        fun push(line: String) {
            buffer.addLast(line)
            while (buffer.size > MAX) buffer.removeFirst()
        }
    }

    private val fmt = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            val ex = sbn.notification?.extras
            val title = ex?.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            val text = ex?.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty().take(120)
            push("${fmt.format(Date(sbn.postTime))} | ${sbn.packageName} | $title | $text")
        } catch (_: Exception) {}
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {}
}
