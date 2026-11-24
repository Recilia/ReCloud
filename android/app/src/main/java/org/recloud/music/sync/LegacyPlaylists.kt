package org.recloud.music.sync

import androidx.room.withTransaction
import java.io.InputStream
import java.io.OutputStream
import kotlinx.serialization.Serializable
import org.recloud.music.data.*
import org.recloud.music.repository.Collection

@Serializable
data class LegacyTrack(
    val videoId: String,
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val duration: Double = 0.0,
)

@Serializable
data class LegacyPlaylist(val id: String, val name: String, val songs: List<LegacyTrack>)

object LegacyPlaylists {
    suspend fun import(input: InputStream, store: Collection): Int {
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (true) {
            val n = input.read(chunk)
            if (n < 0) break
            require(buffer.size() + n <= 8_388_608) { "The playlist file exceeds 8 MB." }
            buffer.write(chunk, 0, n)
        }
        val lists = codec.decodeFromString<List<LegacyPlaylist>>(buffer.toString("UTF-8"))
        return store.db.withTransaction {
            var count = 0
            for (list in lists) {
                require(list.id.length in 1..120 && list.name.isNotBlank()) {
                    "Invalid playlist identifier or name."
                }
                val old = store.dao.mix(list.id)
                if (old?.deleted == true) continue
                val tracks =
                    list.songs.mapNotNull { t ->
                        val s =
                            Song(
                                "yt-" + t.videoId,
                                t.title.take(2000).ifBlank { t.videoId },
                                t.artist.take(2000),
                                t.album.take(2000),
                                duration = (t.duration * 1000).toLong().coerceAtLeast(0),
                            )
                        if (s.youtubeId != null) s else null
                    }
                tracks.forEach { store.dao.put(it) }
                val members = (old?.ids().orEmpty() + tracks.map { it.id }).distinct()
                if (old == null || members != old.ids())
                    store.dao.put(
                        Mix(
                            list.id,
                            old?.name ?: list.name.take(120),
                            codec.encodeToString(members),
                            maxOf(System.currentTimeMillis(), (old?.edited ?: 0) + 1),
                        )
                    )
                count++
            }
            count
        }
    }

    suspend fun export(output: OutputStream, store: Collection): Int {
        val snapshot = store.snapshot()
        val songs = snapshot.songs.associateBy { it.id }
        val lists =
            snapshot.mixes
                .filterNot { it.deleted }
                .map { mix ->
                    LegacyPlaylist(
                        mix.id,
                        mix.name,
                        mix.ids().mapNotNull { id ->
                            val s = songs[id] ?: return@mapNotNull null
                            val video = s.youtubeId ?: return@mapNotNull null
                            LegacyTrack(video, s.title, s.artist, s.album, s.duration / 1000.0)
                        },
                    )
                }
        output.write(codec.encodeToString(lists).toByteArray())
        return lists.sumOf { it.songs.size }
    }
}
