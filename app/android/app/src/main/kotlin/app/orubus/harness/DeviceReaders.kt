package app.orubus.harness

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.CalendarContract
import android.provider.CallLog
import android.provider.ContactsContract
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.accounts.AccountManager
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Permission-gated device readers. Every function returns a Map with ok/out so
 * the Dart layer can ship it straight back over the bridge. Each reader checks
 * its permission FIRST — a missing grant degrades to an honest message, never
 * a crash, never a silent empty result.
 */
object DeviceReaders {

    /** Runtime-requestable permissions we surface in the app's grant screen. */
    val REQUESTABLE = listOf(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.ACCESS_COARSE_LOCATION,
        Manifest.permission.READ_CONTACTS,
        Manifest.permission.WRITE_CONTACTS,
        Manifest.permission.GET_ACCOUNTS,
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_PHONE_NUMBERS,
        Manifest.permission.CALL_PHONE,
        Manifest.permission.READ_CALL_LOG,
        Manifest.permission.WRITE_CALL_LOG,
        Manifest.permission.SEND_SMS,
        Manifest.permission.RECEIVE_SMS,
        Manifest.permission.READ_SMS,
        Manifest.permission.RECEIVE_MMS,
        Manifest.permission.READ_CALENDAR,
        Manifest.permission.WRITE_CALENDAR,
        Manifest.permission.READ_MEDIA_IMAGES,
        Manifest.permission.READ_MEDIA_VIDEO,
        Manifest.permission.READ_MEDIA_AUDIO,
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.POST_NOTIFICATIONS,
        Manifest.permission.RECORD_AUDIO,
        Manifest.permission.CAMERA,
    )

    /** Which of the above are currently granted (only those declared by this build). */
    fun permissionStates(ctx: Context): Map<String, Boolean> {
        val out = HashMap<String, Boolean>()
        for (p in REQUESTABLE) {
            out[p.substringAfterLast('.')] = try {
                ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
            } catch (e: Exception) {
                false
            }
        }
        return out
    }

    private fun granted(ctx: Context, perm: String): Boolean = try {
        ctx.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
    } catch (e: Exception) {
        false
    }

    private fun deny(what: String, perm: String): Map<String, Any> = mapOf(
        "ok" to false,
        "out" to "PERMISSION REQUIRED: $perm not granted — open Device Access and allow $what",
    )

    private fun render(cols: Array<String>, rows: List<List<String>>, head: Int = 40): String {
        val b = StringBuilder(cols.joinToString(" | ")).append('\n')
        for ((i, r) in rows.withIndex()) {
            if (i >= head) {
                b.append("… (${rows.size - head} more rows)").append('\n')
                break
            }
            b.append(r.joinToString(" | ")).append('\n')
        }
        return b.toString().trimEnd()
    }

    // ---- location ----------------------------------------------------------
    @SuppressLint("MissingPermission")
    fun location(ctx: Context): Map<String, Any> {
        if (!granted(ctx, Manifest.permission.ACCESS_FINE_LOCATION) &&
            !granted(ctx, Manifest.permission.ACCESS_COARSE_LOCATION)
        ) return deny("location", "ACCESS_FINE_LOCATION")
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val sb = StringBuilder()
        for (p in lm.allProviders) {
            val last = try { lm.getLastKnownLocation(p) } catch (e: Exception) { null }
            val enabled = try { lm.isProviderEnabled(p) } catch (e: Exception) { false }
            if (last != null) {
                sb.append("provider=$p lat=${last.latitude} lon=${last.longitude} ")
                    .append("acc=${last.accuracy}m alt=${last.altitude}")
                if (last.hasSpeed()) sb.append(" speed=${last.speed}m/s")
                sb.append(" time=").append(SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(last.time)))
                    .append('\n')
            } else {
                sb.append("provider=$p enabled=$enabled (no fix yet)\n")
            }
        }
        return if (sb.isEmpty()) mapOf("ok" to true, "out" to "(no locations available)")
        else mapOf("ok" to true, "out" to sb.toString().trimEnd())
    }

    // ---- contacts ----------------------------------------------------------
    fun contacts(ctx: Context): Map<String, Any> {
        if (!granted(ctx, Manifest.permission.READ_CONTACTS)) return deny("contacts", "READ_CONTACTS")
        val c = ctx.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.TYPE,
            ),
            null, null,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC"
        ) ?: return mapOf("ok" to false, "out" to "contacts query failed")
        var rows: List<List<String>> = emptyList()
        c.use { cur ->
            val out = ArrayList<List<String>>()
            var n = 0
            while (cur.moveToNext() && n < 300) {
                out.add(listOf(cur.getString(0) ?: "", cur.getString(1) ?: "", cur.getString(2) ?: ""))
                n++
            }
            rows = out
        }
        return mapOf("ok" to true, "out" to render(
            arrayOf("name", "number", "type"), rows))
    }

    // ---- call log ----------------------------------------------------------
    fun callLog(ctx: Context): Map<String, Any> {
        if (!granted(ctx, Manifest.permission.READ_CALL_LOG)) return deny("call log", "READ_CALL_LOG")
        val c = ctx.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(
                CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE,
                CallLog.Calls.DATE, CallLog.Calls.DURATION,
            ),
            null, null, CallLog.Calls.DATE + " DESC"
        ) ?: return mapOf("ok" to false, "out" to "call log query failed")
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
        var rows: List<List<String>> = emptyList()
        c.use { cur ->
            val out = ArrayList<List<String>>()
            var n = 0
            while (cur.moveToNext() && n < 200) {
                val date = try { fmt.format(Date(cur.getLong(3))) } catch (e: Exception) { "?" }
                val type = when (cur.getInt(2)) {
                    CallLog.Calls.INCOMING_TYPE -> "IN"
                    CallLog.Calls.OUTGOING_TYPE -> "OUT"
                    CallLog.Calls.MISSED_TYPE -> "MISSED"
                    else -> "type${cur.getInt(2)}"
                }
                out.add(listOf(cur.getString(0) ?: "", cur.getString(1) ?: "", type, date, "${cur.getLong(4)}s"))
                n++
            }
            rows = out
        }
        return mapOf("ok" to true,
            "out" to render(arrayOf("number", "name", "dir", "when", "dur"), rows))
    }

    // ---- sms ---------------------------------------------------------------
    fun sms(ctx: Context): Map<String, Any> {
        if (!granted(ctx, Manifest.permission.READ_SMS)) return deny("sms", "READ_SMS")
        val c = ctx.contentResolver.query(
            android.provider.Telephony.Sms.CONTENT_URI,
            arrayOf(android.provider.Telephony.Sms.ADDRESS, android.provider.Telephony.Sms.BODY,
                android.provider.Telephony.Sms.DATE, android.provider.Telephony.Sms.TYPE),
            null, null, android.provider.Telephony.Sms.DATE + " DESC"
        ) ?: return mapOf("ok" to false, "out" to "sms query failed")
        val fmt = SimpleDateFormat("MM-dd HH:mm", Locale.US)
        var rows: List<List<String>> = emptyList()
        c.use { cur ->
            val out = ArrayList<List<String>>()
            var n = 0
            while (cur.moveToNext() && n < 100) {
                val body = (cur.getString(1) ?: "").take(80)
                val date = try { fmt.format(Date(cur.getLong(2))) } catch (e: Exception) { "?" }
                val dir = if (cur.getInt(3) == 2) "SENT" else "INBOX"
                out.add(listOf(cur.getString(0) ?: "", dir, date, body))
                n++
            }
            rows = out
        }
        return mapOf("ok" to true,
            "out" to render(arrayOf("addr", "dir", "when", "body"), rows))
    }

    fun sendSms(ctx: Context, to: String, body: String): Map<String, Any> {
        if (!granted(ctx, Manifest.permission.SEND_SMS)) return deny("send sms", "SEND_SMS")
        if (to.isEmpty() || body.isEmpty()) return mapOf("ok" to false, "out" to "sendSms: need to + body")
        return try {
            val sm = if (Build.VERSION.SDK_INT >= 31) {
                ctx.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION") SmsManager.getDefault()
            }
            if (sm == null) {
                mapOf("ok" to false, "out" to "SmsManager unavailable")
            } else {
                val parts = sm.divideMessage(body)
                if (parts.size == 1) sm.sendTextMessage(to, null, body, null, null)
                else sm.sendMultipartTextMessage(to, null, parts, null, null)
                mapOf("ok" to true, "out" to "SMS dispatched to $to (${body.length} chars)")
            }
        } catch (e: Exception) {
            mapOf("ok" to false, "out" to "sendSms failed: ${e.message}")
        }
    }

    // ---- installed apps ----------------------------------------------------
    fun installedApps(ctx: Context): Map<String, Any> {
        val pm = ctx.packageManager
        val flags = PackageManager.GET_PERMISSIONS
        val pkgs = try {
            if (Build.VERSION.SDK_INT >= 33) {
                pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(flags.toLong()))
            } else {
                @Suppress("DEPRECATION") pm.getInstalledPackages(flags)
            }
        } catch (e: Exception) {
            return mapOf("ok" to false, "out" to "installedApps failed: ${e.message}")
        }
        val own = ctx.packageName
        val b = StringBuilder("total=${pkgs.size}\n")
        var n = 0
        for (p in pkgs.sortedBy { it.packageName }) {
            if (n >= 400) { b.append("… (truncated)\n"); break }
            val user = (p.applicationInfo?.flags ?: 0) and android.content.pm.ApplicationInfo.FLAG_SYSTEM == 0
            b.append(if (user) "U " else "S ")
                .append(p.packageName)
                .append("  v").append(p.versionName ?: "?")
                .append(if (p.packageName == own) "  <== harness" else "")
                .append('\n')
            n++
        }
        return mapOf("ok" to true, "out" to b.toString().trimEnd())
    }

    // ---- calendar ----------------------------------------------------------
    fun calendar(ctx: Context): Map<String, Any> {
        if (!granted(ctx, Manifest.permission.READ_CALENDAR)) return deny("calendar", "READ_CALENDAR")
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
        val now = System.currentTimeMillis()
        val c = ctx.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(CalendarContract.Events.TITLE, CalendarContract.Events.DTSTART,
                CalendarContract.Events.DTEND, CalendarContract.Events.EVENT_LOCATION),
            CalendarContract.Events.DTSTART + ">=?",
            arrayOf("$now"),
            CalendarContract.Events.DTSTART + " ASC"
        ) ?: return mapOf("ok" to false, "out" to "calendar query failed")
        var rows: List<List<String>> = emptyList()
        c.use { cur ->
            val out = ArrayList<List<String>>()
            var n = 0
            while (cur.moveToNext() && n < 100) {
                out.add(listOf(
                    fmt.format(Date(cur.getLong(1))),
                    fmt.format(Date(if (cur.isNull(2)) 0 else cur.getLong(2))),
                    cur.getString(0) ?: "", cur.getString(3) ?: ""))
                n++
            }
            rows = out
        }
        return mapOf("ok" to true,
            "out" to render(arrayOf("start", "end", "title", "loc"), rows))
    }

    // ---- network / wifi ----------------------------------------------------
    fun netState(ctx: Context): Map<String, Any> {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val b = StringBuilder()
        for (net in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(net) ?: continue
            val kinds = mutableListOf<String>()
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) kinds.add("wifi")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) kinds.add("cellular")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) kinds.add("ethernet")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) kinds.add("vpn")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) kinds.add("bt")
            b.append("net=").append(kinds.joinToString("+"))
                .append(" valid=").append(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
                .append(" down=").append(caps.linkDownstreamBandwidthKbps).append("Kbps")
                .append(" up=").append(caps.linkUpstreamBandwidthKbps).append("Kbps").append('\n')
        }
        val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        if (tm != null) {
            b.append("radio=").append(try { tm.networkTypeName() } catch (e: Exception) { "?" })
                .append(" sim=").append(try { tm.simStateToString() } catch (e: Exception) { "?" })
                .append('\n')
        }
        return mapOf("ok" to true, "out" to b.toString().trimEnd())
    }

    private fun TelephonyManager.networkTypeName(): String = try {
        val m = TelephonyManager::class.java.getMethod("getNetworkTypeName")
        (m.invoke(this) as? String) ?: "?"
    } catch (e: Exception) { "?" }

    private fun TelephonyManager.simStateToString(): String = when (simState) {
        TelephonyManager.SIM_STATE_READY -> "ready"
        TelephonyManager.SIM_STATE_ABSENT -> "absent"
        TelephonyManager.SIM_STATE_PIN_REQUIRED,
        TelephonyManager.SIM_STATE_PUK_REQUIRED,
        TelephonyManager.SIM_STATE_NETWORK_LOCKED -> "locked"
        else -> "state=$simState"
    }

    @SuppressLint("MissingPermission", "WifiManagerLeak")
    fun wifi(ctx: Context): Map<String, Any> {
        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val b = StringBuilder()
        b.append("wifi_enabled=").append(wm.isWifiEnabled).append('\n')
        if (Build.VERSION.SDK_INT < 33 &&
            granted(ctx, Manifest.permission.ACCESS_FINE_LOCATION)) {
            val scans = try { wm.scanResults } catch (e: Exception) { emptyList() }
            b.append("scan_results=").append(scans.size).append('\n')
            for (r in scans.take(30)) {
                b.append("  ssid=").append(escape(r.SSID))
                    .append(" bssid=").append(r.BSSID)
                    .append(" rssi=").append(r.level)
                    .append(" ch=").append(frequencyToChannel(r.frequency)).append('\n')
            }
        } else if (Build.VERSION.SDK_INT >= 33) {
            b.append("(scan results need NEARBY_WIFI_DEVICES on Android 13+)\n")
        }
        return mapOf("ok" to true, "out" to b.toString().trimEnd())
    }

    private fun escape(s: String?) = (s ?: "").replace("\n", "\\n")
    private fun frequencyToChannel(freq: Int): Int = when {
        freq <= 0 -> -1
        freq == 2484 -> 14
        freq < 2484 -> (freq - 2407) / 5
        freq in 4910..4980 -> (freq - 4000) / 5
        freq < 5950 -> (freq - 5000) / 5
        else -> (freq - 5950) / 5
    }

    // ---- clipboard / accounts ----------------------------------------------
    fun clipboard(ctx: Context): Map<String, Any> {
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val item = cm.primaryClip?.getItemAt(0)
        val txt = item?.coerceToText(ctx)?.toString().orEmpty()
        return mapOf("ok" to true,
            "out" to if (txt.isEmpty()) "(clipboard empty)" else txt.take(2000))
    }

    fun accounts(ctx: Context): Map<String, Any> {
        if (!granted(ctx, Manifest.permission.GET_ACCOUNTS)) return deny("accounts", "GET_ACCOUNTS")
        val am = AccountManager.get(ctx)
        val accts = am.accounts
        val b = StringBuilder("count=${accts.size}\n")
        for (a in accts.take(100)) b.append("  ").append(a.type).append(" :: ").append(a.name).append('\n')
        return mapOf("ok" to true, "out" to b.toString().trimEnd())
    }

    // ---- notification buffer (fed by NotifListener) -------------------------
    fun notifBuffer(): Map<String, Any> = mapOf(
        "ok" to true,
        "out" to if (NotifListener.buffer.isEmpty())
            "(no notifications captured — enable Notification access in Device Access)"
        else NotifListener.buffer.joinToString("\n")
    )
}
