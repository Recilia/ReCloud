package org.recloud.music.network

import android.content.Context
import android.content.pm.PackageManager
import java.security.MessageDigest
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

data class VideoEntry(val id: String, val type: String, val title: String, val artist: String = "")

fun videoId(input: String): String? {
    val url = input.trim().toHttpUrlOrNull() ?: return null
    val candidate =
        when (url.host) {
            "youtu.be" -> url.pathSegments.firstOrNull()
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "music.youtube.com" ->
                if (url.encodedPath == "/watch") url.queryParameter("v")
                else if (url.pathSegments.firstOrNull() in setOf("shorts", "embed", "live"))
                    url.pathSegments.getOrNull(1)
                else null
            else -> null
        }
    return candidate?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{11}")) }
}

class YouTubeCatalog(private val app: Context, private val client: OkHttpClient) {
    @Suppress("DEPRECATION")
    private val certificate by lazy {
        val signatures =
            app.packageManager
                .getPackageInfo(app.packageName, PackageManager.GET_SIGNATURES)
                .signatures
        MessageDigest.getInstance("SHA-1")
            .digest(requireNotNull(signatures).first().toByteArray())
            .joinToString("") { "%02X".format(it) }
    }

    fun signingFingerprint() = certificate.chunked(2).joinToString(":")

    suspend fun linkedVideo(id: String): VideoEntry {
        val url =
            "https://www.youtube.com/oembed"
                .toHttpUrl()
                .newBuilder()
                .addQueryParameter("url", "https://www.youtube.com/watch?v=$id")
                .addQueryParameter("format", "json")
                .build()
        return try {
            val obj = client.json(Request.Builder().url(url).build())
            VideoEntry(
                id,
                "video",
                obj.field("title").ifBlank { "YouTube video · $id" },
                obj.field("author_name"),
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            VideoEntry(id, "video", "YouTube video · $id")
        }
    }

    suspend fun list(
        q: String,
        type: String,
        parent: VideoEntry?,
        key: String,
        token: String,
    ): List<VideoEntry> {
        require(key.isNotBlank() || token.isNotBlank()) {
            "Add a YouTube Data API key in Settings, sign in, or paste a YouTube video link."
        }
        val playlist = parent?.type == "playlist"
        val url =
            "https://www.googleapis.com/youtube/v3/"
                .toHttpUrl()
                .newBuilder()
                .addPathSegment(if (playlist) "playlistItems" else "search")
                .addQueryParameter("part", "snippet")
                .addQueryParameter("maxResults", "50")
        if (playlist) url.addQueryParameter("playlistId", parent?.id)
        else {
            url.addQueryParameter("type", if (parent != null) "video" else type)
            if (parent != null) url.addQueryParameter("channelId", parent.id)
            else url.addQueryParameter("q", q)
        }
        val req = Request.Builder().url(url.build()).header("Cache-Control", "no-store")
        if (token.isNotBlank()) req.header("Authorization", "Bearer $token")
        else
            req.header("X-Goog-Api-Key", key)
                .header("X-Android-Package", app.packageName)
                .header("X-Android-Cert", certificate)
        return parse(client.json(req.build()), playlist)
    }

    companion object {
        fun parse(root: JsonObject, playlist: Boolean): List<VideoEntry> =
            root.getValue("items").jsonArray.mapNotNull { parseItem(it, playlist) }

        internal fun parseItem(item: JsonElement, playlist: Boolean): VideoEntry? {
            val obj = item as? JsonObject ?: return null
            val snippet = obj["snippet"] as? JsonObject ?: return null
            val id =
                (if (playlist) snippet["resourceId"] else obj["id"]) as? JsonObject ?: return null
            val type =
                listOf("video", "playlist", "channel").firstOrNull { k ->
                    id.field(k + "Id").isNotEmpty()
                } ?: return null
            val title = snippet.field("title")
            if (
                playlist &&
                    (type != "video" || !id.field("videoId").matches(Regex("[A-Za-z0-9_-]{11}")))
            )
                return null
            if (
                playlist &&
                    title in setOf("Deleted video", "Private video") &&
                    snippet.field("videoOwnerChannelId").isBlank()
            )
                return null
            return VideoEntry(
                id.field(type + "Id"),
                type,
                title,
                snippet.field("videoOwnerChannelTitle").ifBlank { snippet.field("channelTitle") },
            )
        }
    }
}
