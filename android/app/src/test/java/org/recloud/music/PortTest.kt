package org.recloud.music

import java.io.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.recloud.music.data.*
import org.recloud.music.network.*
import org.recloud.music.playback.QueueState
import org.recloud.music.repository.*
import org.recloud.music.sync.packet

class PortTest {
    @Test fun playlistErrorsPreserveGoogleReason() = runBlocking {
        val http = client(403, """{"error":{"details":[{"reason":"SERVICE_DISABLED"}]}}""")
        val e = runCatching { org.recloud.music.auth.YouTubeAccount(http).playlists("fixture") }.exceptionOrNull()
        assertTrue(e is ServiceFailure)
        assertTrue(org.recloud.music.auth.playlistFailureMessage(e as ServiceFailure).contains("Enable YouTube Data API"))
    }

    @Test fun googleInternalErrorsPreserveOnlyDiagnosticCodes() {
        val message = org.recloud.music.auth.internalAuthorizationError("[28444] Developer console configuration includes private@example.com")
        assertTrue(message.contains("8/28444"))
        assertTrue(message.contains("configuration"))
        assertFalse(message.contains("@"))
    }

    private val release =
        codec
            .parseToJsonElement(
                """{"metadata":{"creator":"Alma","title":"Live","licenseurl":"https://creativecommons.org/licenses/by/4.0/"},"files":[{"name":"one.flac","title":"One","size":"900"},{"name":"one.mp3","original":"one.flac","title":"One","length":"1:02","size":"300"},{"name":"cover.jpg"},{"name":"hidden.mp3","private":"true"}]}"""
            )
            .jsonObject

    @Test
    fun metadataSelectsPermittedFormatsAndCredits() {
        val track = ArchiveCatalog.parse("concert", release).single()
        assertEquals("Alma", track.artist)
        assertEquals(62000, track.duration)
        assertTrue(track.archived)
        assertEquals(
            "one.flac",
            ArchiveCatalog.parse("concert", release, "Higher").single().filename,
        )
        assertEquals(
            "one.mp3",
            ArchiveCatalog.parse("concert", release, "Smaller").single().filename,
        )
    }

    @Test
    fun restrictedRecordingsAreExcluded() {
        val restricted = JsonObject(release + ("is_dark" to JsonPrimitive(true)))
        assertTrue(ArchiveCatalog.parse("concert", restricted).isEmpty())
        assertFalse(allowedLicense("https://creativecommons.org.example.com/licenses/by/4.0/"))
        assertFalse(allowedLicense("https://creativecommons.org/unknown"))
    }

    private fun client(code: Int, body: String, inspect: (Request) -> Unit = {}) =
        OkHttpClient.Builder()
            .addInterceptor { chain ->
                inspect(chain.request())
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(code)
                    .message("response")
                    .body(body.toResponseBody("application/json".toMediaType()))
                    .build()
            }
            .build()

    @Test
    fun artistSearchEscapesUserQueryAndReadsArrays() = runBlocking {
        val http =
            client(
                200,
                """{"response":{"docs":[{"identifier":"set","creator":["A","B"],"title":"Live"}]}}""",
            ) {
                val q = it.url.queryParameter("q").orEmpty()
                assertTrue(q.contains("creator:\"Alma\""))
                assertTrue(q.startsWith("collection:netlabels"))
            }
        assertEquals("A, B", ArchiveCatalog(http).search("Alma", Kind.Artists).single().artist)
    }

    @Test
    fun httpAndMalformedErrorsReachCaller() = runBlocking {
        for ((code, body) in listOf(503 to "unavailable", 200 to "not JSON", 200 to "{}")) {
            assertTrue(
                runCatching { ArchiveCatalog(client(code, body)).search("pop", Kind.Albums) }
                    .isFailure
            )
        }
    }

    @Test
    fun youtubeSearchAndPlaylistItemsResolve() {
        val search =
            codec
                .parseToJsonElement(
                    """{"items":[{"id":{"channelId":"abc"},"snippet":{"title":"Jazz"}},{"id":null}]}"""
                )
                .jsonObject
        assertEquals("channel", YouTubeCatalog.parse(search, false).single().type)
        val playlist =
            codec
                .parseToJsonElement(
                    """{"items":[{"snippet":{"title":"Demo","resourceId":{"videoId":"01234567890"}}}]}"""
                )
                .jsonObject
        assertEquals("01234567890", YouTubeCatalog.parse(playlist, true).single().id)
        assertEquals("01234567890", videoId("https://music.youtube.com/watch?v=01234567890"))
        assertNull(videoId("https://youtu.be.evil.example/01234567890"))
    }

    @Test
    fun persistedQueueKeepsModesAndBoundsIndex() {
        val saved = QueueState(listOf("a", "b"), 9, 1234, true, 2)
        val read = codec.decodeFromString<QueueState>(codec.encodeToString(saved))
        assertEquals(saved, read)
        assertEquals(1, read.validIndex())
    }

    @Test
    fun mergeIsIdempotentAndDeterministic() {
        val a = Listening("s", "d", 2, 700, 20)
        val b = Listening("s", "d", 3, 500, 40)
        assertEquals(mergeCounts(a, b), mergeCounts(b, a))
        assertEquals(mergeCounts(a, b), mergeCounts(mergeCounts(a, b), b))
        assertTrue(newer(10, 10, "z", "a"))
        assertFalse(newer(9, 10, "z", "a"))
    }

    @Test
    fun syncFramingRejectsOversizeAndTruncation() {
        val packet =
            LibraryPacket(
                songs = emptyList(),
                mixes = emptyList(),
                stars = emptyList(),
                stats = emptyList(),
            )
        val bytes =
            ByteArrayOutputStream().also { DataOutputStream(it).packet(packet) }.toByteArray()
        assertEquals(packet, DataInputStream(bytes.inputStream()).packet())
        assertTrue(
            runCatching { DataInputStream(bytes.copyOf(bytes.size - 1).inputStream()).packet() }
                .isFailure
        )
        assertTrue(
            runCatching { DataInputStream(byteArrayOf(127, 127, 127, 127).inputStream()).packet() }
                .isFailure
        )
    }
}
