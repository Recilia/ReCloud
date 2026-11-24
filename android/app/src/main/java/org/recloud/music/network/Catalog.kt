package org.recloud.music.network

import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.recloud.music.data.*

data class Release(
    val item: String,
    val title: String,
    val artist: String,
    val video: Boolean = false,
) {
    val art
        get() = archiveUrl("services", "img", item)
}

enum class Kind {
    Songs,
    Videos,
    Albums,
    Artists,
}

interface DiscoveryProvider {
    suspend fun search(query: String, kind: Kind): List<Release>
}

interface MetadataProvider {
    suspend fun tracks(item: String): List<Song>
}

fun archiveUrl(vararg parts: String) =
    "https://archive.org"
        .toHttpUrl()
        .newBuilder()
        .apply { parts.forEach { addPathSegment(it) } }
        .build()
        .toString()

fun JsonObject.field(key: String): String =
    when (val v = get(key)) {
        is JsonPrimitive -> v.contentOrNull.orEmpty()
        is JsonArray -> v.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.joinToString(", ")
        else -> ""
    }

class ServiceFailure(val status: Int, val reasons: List<String>) : IOException("Service returned HTTP $status.")

private fun Response.serviceFailure(): ServiceFailure {
    val reasons = runCatching {
        val error = codec.parseToJsonElement(peekBody(16384).string()).jsonObject["error"]?.jsonObject
        listOf("errors", "details").flatMap { key ->
            (error?.get(key) as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.field("reason") }
        }.filter { it.matches(Regex("[a-zA-Z_]{1,64}")) }
    }.getOrDefault(emptyList())
    return ServiceFailure(code, reasons)
}

suspend fun OkHttpClient.json(request: Request): JsonObject = suspendCancellableCoroutine { cont ->
    val call = newCall(request)
    cont.invokeOnCancellation { call.cancel() }
    call.enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (cont.isActive)
                    cont.resumeWithException(IOException("Could not reach the music service.", e))
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    try {
                        if (!it.isSuccessful) throw it.serviceFailure()
                        val source = it.body?.source() ?: throw IOException("Empty response.")
                        if (source.request(6L * 1024 * 1024 + 1))
                            throw IOException("Response exceeds the catalog size limit.")
                        val obj = codec.parseToJsonElement(source.readUtf8()).jsonObject
                        if (cont.isActive) cont.resume(obj)
                    } catch (e: Exception) {
                        if (cont.isActive) cont.resumeWithException(e)
                    }
                }
            }
        }
    )
}

class ArchiveCatalog(
    private val client: OkHttpClient,
    private val quality: suspend () -> String = { "Balanced" },
) : DiscoveryProvider, MetadataProvider {
    override suspend fun search(query: String, kind: Kind): List<Release> {
        val terms =
            Regex("[\\p{L}\\p{N}]+").findAll(query.take(160)).map { it.value }.take(12).toList()
        val base =
            if (kind == Kind.Videos) "mediatype:movies AND subject:music"
            else "collection:netlabels AND mediatype:audio"
        val expression = buildString {
            append("$base AND licenseurl:(*creativecommons.org*)")
            terms.forEach {
                append(if (kind == Kind.Artists) " AND creator:\"$it\"" else " AND \"$it\"")
            }
        }
        val url =
            "https://archive.org/advancedsearch.php"
                .toHttpUrl()
                .newBuilder()
                .addQueryParameter("q", expression)
                .addQueryParameter("fl[]", "identifier,title,creator")
                .addQueryParameter("output", "json")
                .addQueryParameter("rows", "30")
                .apply { if (terms.isEmpty()) addQueryParameter("sort[]", "downloads desc") }
                .build()
        val root = client.json(Request.Builder().url(url).build())
        return root.getValue("response").jsonObject.getValue("docs").jsonArray.mapNotNull { entry ->
            val obj = entry as? JsonObject ?: return@mapNotNull null
            val id = obj.field("identifier")
            if (id.isBlank()) null
            else
                Release(
                    id,
                    obj.field("title").ifBlank { id },
                    obj.field("creator"),
                    kind == Kind.Videos,
                )
        }
    }

    override suspend fun tracks(item: String): List<Song> =
        parse(
            item,
            client.json(Request.Builder().url(archiveUrl("metadata", item)).build()),
            quality(),
        )

    companion object {
        fun parse(item: String, root: JsonObject, quality: String = "Balanced"): List<Song> {
            val meta = root.getValue("metadata").jsonObject
            val license = meta.field("licenseurl")
            if (
                !allowedLicense(license) ||
                    root.field("is_dark") == "true" ||
                    meta.field("access-restricted-item") == "true"
            )
                return emptyList()
            val files = root.getValue("files").jsonArray.mapNotNull { it as? JsonObject }
            return files
                .filter {
                    it.field("name").substringAfterLast('.').lowercase() in
                        listOf("mp3", "ogg", "flac", "m4a", "wav") && it.field("private") != "true"
                }
                .sortedBy { f ->
                    val ext = f.field("name").substringAfterLast('.').lowercase()
                    when (quality) {
                        "Higher" -> if (ext in listOf("flac", "wav")) 0L else 1L
                        "Smaller" -> f.field("size").toLongOrNull() ?: Long.MAX_VALUE
                        else -> if (ext == "mp3") 0L else 1L
                    }
                }
                .distinctBy {
                    it.field("original").ifBlank { it.field("name") }.substringBeforeLast('.')
                }
                .map { f ->
                    val file = f.field("name")
                    val length =
                        f.field("length").split(':').fold(0.0) { sum, part ->
                            sum * 60 + (part.toDoubleOrNull() ?: 0.0)
                        }
                    Song(
                        archiveId(item, file),
                        f.field("title").ifBlank { file.substringBeforeLast('.') },
                        f.field("artist").ifBlank { meta.field("creator") },
                        meta.field("title"),
                        item,
                        file,
                        archiveUrl("services", "img", item),
                        license,
                        (length * 1000).toLong().coerceAtLeast(0),
                        f.field("bitrate").toIntOrNull() ?: 0,
                    )
                }
                .filter { it.archived }
                .sortedBy { it.filename }
        }
    }
}
