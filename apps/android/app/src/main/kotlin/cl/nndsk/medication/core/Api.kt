package cl.nndsk.medication.core

import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.Retrofit
import retrofit2.http.*

interface WireApi {
    @GET suspend fun get(@Url path: String, @Header("Authorization") token: String, @QueryMap query: Map<String, String>): Response<ResponseBody>
    @POST suspend fun post(@Url path: String, @Header("Authorization") token: String, @Body body: RequestBody): Response<ResponseBody>
    @PUT suspend fun put(@Url path: String, @Header("Authorization") token: String, @Body body: RequestBody): Response<ResponseBody>
    @DELETE suspend fun delete(@Url path: String, @Header("Authorization") token: String): Response<ResponseBody>
}

class Api(private val identity: Identity) {
    private val wire: WireApi by lazy {
        validateConfiguration()
        Retrofit.Builder().baseUrl(BuildConfigUrl()).client(httpClient).build().create(WireApi::class.java)
    }
    private fun BuildConfigUrl() = cl.nndsk.medication.BuildConfig.API_BASE_URL.trimEnd('/') + "/"
    suspend fun request(path: String, body: String? = null, query: Map<String, String> = emptyMap(), delete: Boolean = false, put: Boolean = false): String {
        suspend fun send(force: Boolean): Response<ResponseBody> {
            val token = "Bearer ${identity.token(force)}"
            return when {
                delete -> wire.delete(path, token)
                put && body != null -> wire.put(path, token, body.toRequestBody("application/json".toMediaType()))
                body != null -> wire.post(path, token, body.toRequestBody("application/json".toMediaType()))
                else -> wire.get(path, token, query)
            }
        }
        var result = send(false)
        if (result.code() == 401) { result.errorBody()?.close(); result = send(true) }
        if (!result.isSuccessful) { result.errorBody()?.close(); throw ApiFailure(result.code()) }
        return result.body()?.use { it.string() } ?: ""
    }
    suspend inline fun <reified T> get(path: String, query: Map<String, String> = emptyMap()): T = wireJson.decodeFromString(request(path, query = query))
    suspend inline fun <reified T> pages(path: String, query: Map<String, String> = emptyMap()): List<T> {
        val all = mutableListOf<T>(); val seen = mutableSetOf<String>(); var cursor = ""
        do {
            val page = get<Page<T>>(path, query + if (cursor.isEmpty()) emptyMap() else mapOf("cursor" to cursor))
            all += page.items; cursor = page.nextCursor
            check(cursor.isEmpty() || seen.add(cursor))
        } while (cursor.isNotEmpty())
        return all
    }
}
