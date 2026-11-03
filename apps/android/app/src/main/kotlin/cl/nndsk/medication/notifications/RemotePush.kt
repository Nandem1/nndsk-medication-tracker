package cl.nndsk.medication.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import cl.nndsk.medication.BuildConfig
import cl.nndsk.medication.MainActivity
import cl.nndsk.medication.MedicationApplication
import cl.nndsk.medication.R
import cl.nndsk.medication.core.Api
import cl.nndsk.medication.core.Identity
import cl.nndsk.medication.core.wireJson
import com.google.android.gms.tasks.Task
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@Serializable
data class PushDevice(val device_id: String, val platform: String = "fcm", val token: String, val permission: String)

fun pushDeviceID(installation: String, owner: String): String =
    UUID.nameUUIDFromBytes("$installation/$owner".toByteArray(Charsets.UTF_8)).toString()

private suspend fun <T> Task<T>.result(): T = suspendCancellableCoroutine { continuation ->
    addOnCompleteListener { task ->
        if (continuation.isActive) {
            if (task.isSuccessful) continuation.resume(task.result)
            else continuation.resumeWithException(IllegalStateException("Push operation failed"))
        }
    }
}

class RemotePushRegistration(private val context: Context, private val identity: Identity, private val api: Api) {
    private val mutex = Mutex()
    private val status = MutableStateFlow("Avisos remotos sin configurar.")
    val diagnostic = status.asStateFlow()
    private var suspended = false
    private val configured = BuildConfig.FIREBASE_PROJECT_ID.isNotBlank() && BuildConfig.FIREBASE_APP_ID.isNotBlank() &&
        BuildConfig.FIREBASE_SENDER_ID.isNotBlank() && BuildConfig.AUTH_EMULATOR.isBlank()
    private val installation by lazy {
        val file = File(context.noBackupFilesDir, "push-installation")
        if (file.exists()) file.readText() else UUID.randomUUID().toString().also { file.writeText(it) }
    }
    private fun messaging(): FirebaseMessaging {
        if (FirebaseApp.getApps(context).isEmpty()) {
            FirebaseApp.initializeApp(context, FirebaseOptions.Builder()
                .setApplicationId(BuildConfig.FIREBASE_APP_ID).setApiKey(BuildConfig.FIREBASE_API_KEY)
                .setProjectId(BuildConfig.FIREBASE_PROJECT_ID).setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID).build())
        }
        return FirebaseMessaging.getInstance()
    }
    fun initialize() {
        if (configured) {
            try { messaging().isAutoInitEnabled = false }
            catch (_: Exception) { status.value = "No se pudo configurar el servicio de avisos remotos." }
        }
        createChannel()
    }
    fun createChannel() {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Avisos del cuidador", NotificationManager.IMPORTANCE_DEFAULT))
    }
    private fun permitted(): Boolean = NotificationManagerCompat.from(context).areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        context.getSystemService(NotificationManager::class.java).getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE

    suspend fun signedIn() = mutex.withLock { suspended = false }

    suspend fun reconcile() = mutex.withLock {
        val owner = identity.uid ?: return@withLock
        if (!configured || suspended) return@withLock
        try {
            val client = messaging()
            val allowed = permitted()
            client.isAutoInitEnabled = allowed
            val token = if (allowed) withTimeoutOrNull(10_000) { client.token.result() } ?: error("Push registration timed out") else ""
            api.request("v1/devices", wireJson.encodeToString(PushDevice(pushDeviceID(installation, owner), token = token, permission = if (allowed) "granted" else "denied")))
            status.value = if (allowed) "Avisos remotos registrados. La entrega depende del sistema y la conexión." else "Avisos remotos sin permiso."
        } catch (e: CancellationException) { throw e }
        catch (_: Exception) { status.value = "Registro de avisos remotos pendiente. Vuelve a sincronizar." }
    }

    suspend fun signOut(): String? = mutex.withLock {
        suspended = true
        val owner = identity.uid ?: return@withLock null
        if (!configured) return@withLock null
        val removed = withTimeoutOrNull(5_000) {
            try { api.request("v1/devices/${pushDeviceID(installation, owner)}", delete = true); true }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { false }
        } ?: false
        try {
            val client = messaging()
            client.isAutoInitEnabled = false
            withTimeoutOrNull(5_000) { client.deleteToken().result() }
        } catch (e: CancellationException) { throw e }
        catch (_: Exception) { }
        context.getSystemService(NotificationManager::class.java).cancel("caregiver", 1)
        status.value = "Avisos remotos desactivados en este teléfono."
        if (removed) null else "La sesión se cerró. El registro remoto no se pudo desactivar en el servidor; podría llegar un aviso genérico hasta que venza."
    }

    companion object { const val CHANNEL = "caregiver-alerts" }
}

class CaregiverMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        val app = application as MedicationApplication
        app.backgroundScope.launch { app.remotePush.reconcile() }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val app = application as MedicationApplication
        if (app.identity.uid == null || !NotificationManagerCompat.from(this).areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, RemotePushRegistration.CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_foreground).setContentTitle("Aviso del cuidador")
            .setContentText("Abre la app para revisar información pendiente.").setContentIntent(open)
            .setAutoCancel(true).setOnlyAlertOnce(true).setVisibility(NotificationCompat.VISIBILITY_PRIVATE).build()
        NotificationManagerCompat.from(this).notify("caregiver", 1, notification)
    }
}
