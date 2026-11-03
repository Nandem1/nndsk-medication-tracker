package cl.nndsk.medication.notifications

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import cl.nndsk.medication.MainActivity
import cl.nndsk.medication.MedicationApplication
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

fun reminderDoses(snapshot: Snapshot, pending: List<PendingOperation>, now: Instant): List<Dose> {
    val blocked = pending.map { it.dose }.toSet()
    return snapshot.doses.filter { !it.declared() && it.id !in blocked && Instant.parse(it.scheduledAt) > now }
        .sortedBy { it.scheduledAt }.take(128)
}

class Reminders(private val context: Context, private val db: LocalDatabase, private val identity: Identity) {
    private val lock = Mutex()
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val preferences = context.getSharedPreferences("reminders", Context.MODE_PRIVATE)
    init { manager.createNotificationChannel(NotificationChannel("doses", "Recordatorios de tomas", NotificationManager.IMPORTANCE_DEFAULT).apply { lockscreenVisibility = Notification.VISIBILITY_PRIVATE }) }

    fun permitted(): Boolean = NotificationManagerCompat.from(context).areNotificationsEnabled() && manager.getNotificationChannel("doses").importance != NotificationManager.IMPORTANCE_NONE
    fun exact(): Boolean = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
    fun diagnostic(): String = when {
        preferences.getBoolean("failed", false) -> "No se pudieron renovar los recordatorios. Abre la app y sincroniza."
        !permitted() -> "Permiso de notificaciones denegado"
        !exact() -> "Precisión limitada. Android puede retrasar los recordatorios."
        else -> "Recordatorios habilitados. Su entrega depende de Android y la batería."
    }
    private fun alarm(uri: String): PendingIntent = PendingIntent.getBroadcast(context, 0,
        Intent(context, ReminderReceiver::class.java).setAction("cl.nndsk.medication.REMIND").setData(Uri.parse(uri)),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    suspend fun reconcile() = withContext(Dispatchers.IO) { lock.withLock {
        preferences.edit().putBoolean("failed", false).apply()
        val old = preferences.getStringSet("scheduled", emptySet()).orEmpty()
        old.forEach { alarms.cancel(alarm(it)) }
        check(preferences.edit().remove("scheduled").commit())
        manager.cancelAll()
        val owner = identity.uid ?: return@withLock
        if (!permitted()) return@withLock
        val scheduled = mutableSetOf<String>()
        for (stored in db.local().snapshots(owner)) {
            val snapshot = wireJson.decodeFromString<Snapshot>(stored.json)
            val operations = db.local().operations(owner, stored.patient)
            for (dose in reminderDoses(snapshot, operations, Instant.now())) {
                val uri = Uri.Builder().scheme("medication").authority("dose").appendPath(owner).appendPath(stored.patient).appendPath(dose.id).appendQueryParameter("at", dose.scheduledAt).build().toString()
                val time = Instant.parse(dose.scheduledAt).toEpochMilli()
                scheduled += uri
                check(preferences.edit().putStringSet("scheduled", scheduled.toSet()).commit())
                try {
                    if (exact()) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, time, alarm(uri))
                    else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, time, alarm(uri))
                } catch (_: SecurityException) { alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, time, alarm(uri)) }
            }
        }
    }
    }
    suspend fun deliver(uri: Uri) = lock.withLock {
        val parts = uri.pathSegments
        if (parts.size != 3 || parts[0] != identity.uid || !permitted()) return@withLock
        val stored = db.local().snapshot(parts[0], parts[1]) ?: return@withLock
        val snapshot = wireJson.decodeFromString<Snapshot>(stored.json)
        val dose = snapshot.doses.find { it.id == parts[2] } ?: return@withLock
        if (uri.getQueryParameter("at") != dose.scheduledAt || Instant.parse(dose.scheduledAt) > Instant.now()) return@withLock
        if (dose.declared() || db.local().operations(parts[0], parts[1]).any { it.dose == dose.id }) return@withLock
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return@withLock
        val intent = Intent(context, MainActivity::class.java).setData(uri).setFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val open = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, "doses").setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("Recordatorio de toma").setContentText("Abre la app para revisar tu agenda.")
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setContentIntent(open).setAutoCancel(true).build()
        try { manager.notify(uri.toString(), 1, notification) } catch (_: SecurityException) { /* Permission can be revoked between check and delivery. */ }
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val app = context.applicationContext as MedicationApplication
        CoroutineScope(Dispatchers.IO).launch {
            try {
                if (intent.action == "cl.nndsk.medication.REMIND") intent.data?.let { app.reminders.deliver(it) }
                else app.reminders.reconcile()
            } catch (_: Exception) {
                context.getSharedPreferences("reminders", Context.MODE_PRIVATE).edit().putBoolean("failed", true).apply()
            } finally { pending.finish() }
        }
    }
}
