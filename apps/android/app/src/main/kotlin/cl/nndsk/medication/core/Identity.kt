package cl.nndsk.medication.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import cl.nndsk.medication.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.net.URI
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class ApiFailure(val status: Int) : Exception("Request failed")

val httpClient: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS)
    .callTimeout(30, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).build()

fun validateConfiguration() {
    val url = URI(BuildConfig.API_BASE_URL)
    require(url.host != null && url.userInfo == null && url.rawQuery == null && url.fragment == null)
    val local = url.host in listOf("localhost", "127.0.0.1", "10.0.2.2") || url.host.endsWith(".local")
    require(url.scheme == "https" || (BuildConfig.DEBUG && url.scheme == "http" && local))
    require(BuildConfig.AUTH_EMULATOR.isEmpty() || (BuildConfig.DEBUG && URI(BuildConfig.AUTH_EMULATOR).host in listOf("localhost", "127.0.0.1", "10.0.2.2")))
}

@Serializable
data class Credentials(val uid: String, val token: String, val refresh: String, val expires: Long, val invitationToken: String? = null, val invitationOperation: String? = null, val email: String = "", val caregiverPreference: Boolean? = null)

class SecretStore(context: Context, filename: String = "identity.enc") {
    private val file = AtomicFile(File(context.noBackupFilesDir, filename))
    private val deletionPending = File(context.noBackupFilesDir, "$filename.deleting")
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("medication-session", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("medication-session", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun read(): Credentials? {
        check(!deletionPending.exists()) { "Session cleanup is incomplete" }
        if (!file.baseFile.exists()) return null
        val bytes = file.readFully()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return wireJson.decodeFromString(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }
    fun save(value: Credentials) {
        if (deletionPending.exists()) clear()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val bytes = cipher.iv + cipher.doFinal(wireJson.encodeToString(value).toByteArray())
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) } catch (e: Exception) { file.failWrite(stream); throw e }
    }
    fun clear() {
        deletionPending.writeText("pending")
        file.delete()
        check(!file.baseFile.exists()) { "Session cleanup failed" }
        check(deletionPending.delete()) { "Session cleanup marker could not be removed" }
    }
}

class Identity(private val secrets: SecretStore, private val tokenExchange: (suspend (String) -> JsonObject)? = null) {
    private val lock = Mutex()
    private val refreshScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var refreshing: Deferred<String>? = null
    private var session = 0L
    var storageFailure = false
        private set
    private var credentials = try { secrets.read() } catch (_: Exception) { storageFailure = true; null }
    val uid: String? get() = credentials?.uid
    val email: String get() = credentials?.email.orEmpty()
    val caregiverPreference: Boolean? get() = credentials?.caregiverPreference

    private fun endpoint(host: String, path: String): String {
        validateConfiguration()
        val origin = if (BuildConfig.AUTH_EMULATOR.isBlank()) "https://$host" else "${BuildConfig.AUTH_EMULATOR}/$host"
        return "$origin/$path?key=${BuildConfig.FIREBASE_API_KEY}"
    }
    private suspend fun post(url: String, body: RequestBody): JsonObject = withContext(Dispatchers.IO) {
        httpClient.newCall(Request.Builder().url(url).post(body).build()).execute().use {
            if (!it.isSuccessful) throw ApiFailure(if (it.code >= 500 || it.code == 429) 503 else 401)
            wireJson.parseToJsonElement(it.body!!.string()).jsonObject
        }
    }
    suspend fun signIn(email: String, password: String, register: Boolean = false) = lock.withLock {
        require(!register || password.length >= 8) { "Usa al menos 8 caracteres." }
        validateConfiguration()
        val body = buildJsonObject { put("email", email.trim()); put("password", password); put("returnSecureToken", true) }
        val data = post(endpoint("identitytoolkit.googleapis.com", if (register) "v1/accounts:signUp" else "v1/accounts:signInWithPassword"), body.toString().toRequestBody("application/json".toMediaType()))
        val value = Credentials(data.getValue("localId").jsonPrimitive.content, data.getValue("idToken").jsonPrimitive.content,
            data.getValue("refreshToken").jsonPrimitive.content, System.currentTimeMillis() + data.getValue("expiresIn").jsonPrimitive.long * 1000)
        require(credentials == null || credentials?.uid == value.uid) { "Cierra la sesión actual antes de cambiar de cuenta." }
        val persisted = value.copy(invitationToken = credentials?.invitationToken, invitationOperation = credentials?.invitationOperation, email = email.trim(), caregiverPreference = credentials?.caregiverPreference)
        secrets.save(persisted); credentials = persisted; storageFailure = false; session++; refreshing = null
        value.uid
    }
    suspend fun resetPassword(email: String) {
        val body = buildJsonObject { put("email", email.trim()); put("requestType", "PASSWORD_RESET") }
        try { post(endpoint("identitytoolkit.googleapis.com", "v1/accounts:sendOobCode"), body.toString().toRequestBody("application/json".toMediaType())) }
        catch (e: ApiFailure) { if (e.status != 401) throw e }
    }
    suspend fun setCaregiverPreference(value: Boolean) = lock.withLock {
        val next = (credentials ?: throw ApiFailure(401)).copy(caregiverPreference = value)
        secrets.save(next); credentials = next
    }
    suspend fun token(rejectedToken: String? = null): String {
        val task = lock.withLock {
            val current = credentials ?: throw ApiFailure(401)
            if (current.token != rejectedToken && current.expires > System.currentTimeMillis() + 60_000) return current.token
            refreshing ?: run {
                val generation = session
                refreshScope.async(start = CoroutineStart.LAZY) {
                    lock.withLock refresh@ {
                        val latest = credentials ?: throw ApiFailure(401)
                        if (session != generation) throw ApiFailure(401)
                        if (latest.token != current.token && latest.expires > System.currentTimeMillis() + 60_000) return@refresh latest.token
                        val data = tokenExchange?.invoke(latest.refresh) ?: post(endpoint("securetoken.googleapis.com", "v1/token"), FormBody.Builder().add("grant_type", "refresh_token").add("refresh_token", latest.refresh).build())
                        val fresh = latest.copy(token = data.getValue("id_token").jsonPrimitive.content, refresh = data.getValue("refresh_token").jsonPrimitive.content,
                            expires = System.currentTimeMillis() + data.getValue("expires_in").jsonPrimitive.long * 1000)
                        secrets.save(fresh); credentials = fresh
                        fresh.token
                    }
                }.also { refreshing = it; it.start() }
            }
        }
        try { return task.await() }
        finally {
            withContext(NonCancellable) {
                runCatching { task.await() }
                lock.withLock { if (refreshing === task) refreshing = null }
            }
        }
    }
    suspend fun invitationOperation(token: String): String = lock.withLock {
        val current = credentials ?: throw ApiFailure(401)
        if (current.invitationToken == token && current.invitationOperation != null) return@withLock current.invitationOperation
        val id = java.util.UUID.randomUUID().toString()
        val next = current.copy(invitationToken = token, invitationOperation = id)
        secrets.save(next); credentials = next
        id
    }
    suspend fun clearInvitation() = lock.withLock {
        credentials?.let { current ->
            val next = current.copy(invitationToken = null, invitationOperation = null)
            secrets.save(next); credentials = next
        }
    }
    suspend fun clear() = lock.withLock {
        try { secrets.clear(); storageFailure = false }
        finally { credentials = null; session++; refreshing = null }
    }
}
