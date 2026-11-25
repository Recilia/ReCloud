package org.recloud.music.viewmodel

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.*
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.room.withTransaction
import androidx.work.WorkManager
import java.util.LinkedHashMap
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.recloud.music.ReCloud
import org.recloud.music.auth.*
import org.recloud.music.data.*
import org.recloud.music.downloads.Offline
import org.recloud.music.network.*
import org.recloud.music.playback.MusicService
import org.recloud.music.playback.media

class MusicModel(application: Application) : AndroidViewModel(application), Player.Listener {
    val app = application as ReCloud
    val store = app.collection
    val dao = store.dao
    val account = YouTubeAccount(app.client)
    val apiKey = ApiKey(app)
    val youtube = YouTubeCatalog(app, app.client)
    private var token = ""
    var signedIn by mutableStateOf(false)
        private set

    private fun searchKey() =
        apiKey.read().ifBlank { org.recloud.music.BuildConfig.YOUTUBE_API_KEY }

    internal fun playlistReader(id: String) = account.reader(id, token)

    var accountSession by mutableStateOf("")
        private set
    var playlistsLoading by mutableStateOf(false)
        private set
    var playlistsError by mutableStateOf("")
        private set

    var playlists by mutableStateOf(emptyList<YouTubeLink>())
        private set

    var message by mutableStateOf("")
        private set

    var home by mutableStateOf(emptyList<Release>())
        private set

    var homeError by mutableStateOf("")
        private set

    var homeLoading by mutableStateOf(false)
        private set

    var releases by mutableStateOf(emptyList<Release>())
        private set

    var matches by mutableStateOf(emptyList<Song>())
        private set

    var videos by mutableStateOf(emptyList<VideoEntry>())
        private set

    var busy by mutableStateOf(false)
        private set

    var resultNote by mutableStateOf("")
        private set

    var album by mutableStateOf<Release?>(null)
        private set

    var albumSongs by mutableStateOf(emptyList<Song>())
        private set

    var albumNote by mutableStateOf("")
        private set

    var loadingAlbum by mutableStateOf(false)
        private set

    var video by mutableStateOf<VideoEntry?>(null)
    var controller by mutableStateOf<MediaController?>(null)
        private set

    var revision by mutableIntStateOf(0)
        private set

    val work = WorkManager.getInstance(app).getWorkInfosByTagFlow(Offline.TAG)
    private val searchCache =
        object : LinkedHashMap<Pair<String, Kind>, List<Release>>(16, 0.75f, true) {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<Pair<String, Kind>, List<Release>>?
            ) = size > 32
        }
    private var searching: Job? = null
    private var browsing: Job? = null
    private var accountJob: Job? = null
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private val future =
        MediaController.Builder(
                app,
                SessionToken(app, ComponentName(app, MusicService::class.java)),
            )
            .buildAsync()

    init {
        future.addListener(
            {
                runCatching { future.get() }
                    .onSuccess {
                        controller = it
                        it.addListener(this)
                    }
                    .onFailure { notice("Could not connect to the music player.") }
            },
            ContextCompat.getMainExecutor(app),
        )
        task { Offline.reconcile(app) }
        refreshHome()
    }

    fun notice(text: String) {
        message = text
    }

    fun task(block: suspend () -> Unit) =
        viewModelScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                notice(e.message?.take(220) ?: "Operation failed. Try again.")
            }
        }

    fun refreshHome() {
        if (homeLoading) return
        task {
            homeLoading = true
            homeError = ""
            try {
                home = app.catalog.search("", Kind.Albums)
            } catch (e: Exception) {
                homeError =
                    "Could not load Internet Archive releases. Check your connection and retry."
            } finally {
                homeLoading = false
            }
        }
    }

    fun search(query: String, source: String, filter: String, parent: VideoEntry? = null) {
        searching?.cancel()
        releases = emptyList()
        matches = emptyList()
        videos = emptyList()
        resultNote = ""
        if (query.isBlank() && parent == null) {
            busy = false
            return
        }
        searching = task {
            busy = true
            try {
                if (parent == null) {
                    dao.put(SearchTerm(query.trim().take(200), System.currentTimeMillis()))
                    dao.trimHistory()
                }
                if (source == "YouTube") {
                    val direct = videoId(query)
                    videos =
                        if (direct != null && parent == null) listOf(youtube.linkedVideo(direct))
                        else youtube.list(query, filter, parent, searchKey(), token)
                } else {
                    val kind = Kind.valueOf(filter)
                    val key = query to kind
                    if (kind == Kind.Songs)
                        matches =
                            dao.allSongs().filter {
                                it.title.contains(query, true) || it.artist.contains(query, true)
                            }
                    val results =
                        searchCache[key]
                            ?: app.catalog.search(query, kind).also { searchCache[key] = it }
                    if (kind == Kind.Songs) {
                        val local = matches
                        val found = coroutineScope {
                            results
                                .take(6)
                                .map { async { app.catalog.tracks(it.item) } }
                                .awaitAll()
                                .flatten()
                        }
                        matches =
                            (local +
                                    found.filter {
                                        it.title.contains(query, true) ||
                                            it.artist.contains(query, true)
                                    })
                                .distinctBy { it.id }
                        releases = results
                    } else releases = results
                }
                if (matches.isEmpty() && releases.isEmpty() && videos.isEmpty())
                    resultNote = "No matches found."
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                resultNote =
                    when {
                        source == "YouTube" && e.message?.contains("401") == true ->
                            "YouTube access expired. Reconnect your Google account in Settings."
                        source == "YouTube" && e.message?.contains("403") == true ->
                            "YouTube denied this request. Check the API key, app restrictions, and project quota."
                        else -> e.message?.take(200) ?: "Search failed. Try again."
                    }
            } finally {
                if (currentCoroutineContext().isActive) busy = false
            }
        }
    }

    fun browse(release: Release?) {
        browsing?.cancel()
        album = release
        albumSongs = emptyList()
        albumNote = ""
        if (release == null) {
            loadingAlbum = false
            return
        }
        browsing = task {
            loadingAlbum = true
            try {
                albumSongs = app.catalog.tracks(release.item)
                if (albumSongs.isEmpty())
                    albumNote = "This release has no playable, licensed audio files."
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                albumNote = "Could not load this release. Check your connection."
            } finally {
                if (currentCoroutineContext().isActive) loadingAlbum = false
            }
        }
    }

    fun access(value: String) {
        accountJob?.cancel()
        if (token != value) {
            clearAccountQueue()
            accountSession = java.util.UUID.randomUUID().toString()
            playlists = emptyList()
        }
        token = value
        signedIn = true
        playlistsLoading = true
        playlistsError = ""
        accountJob = task {
            try {
                playlists = account.playlists(value)
                notice("Google account connected.")
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                if (e is ServiceFailure && e.status == 401 && "youtubeSignupRequired" !in e.reasons) signOut()
                playlistsError = playlistFailureMessage(e)
                notice(playlistsError)
            } finally {
                if (currentCoroutineContext().isActive) playlistsLoading = false
            }
        }
    }

    fun refreshAccountPlaylists() { if (token.isNotEmpty()) access(token) }

    fun signOut() {
        clearAccountQueue()
        if (token.isNotBlank())
            com.google.android.gms.auth.api.identity.Identity.getAuthorizationClient(app)
                .clearToken(
                    com.google.android.gms.auth.api.identity.ClearTokenRequest.builder()
                        .setToken(token)
                        .build()
                )
        accountJob?.cancel()
        searching?.cancel()
        token = ""
        accountSession = ""
        playlistsLoading = false
        playlistsError = ""
        signedIn = false
        playlists = emptyList()
        videos = emptyList()
        busy = false
    }

    var videoQueue by mutableStateOf(emptyList<VideoEntry>())
        private set

    var showVideo by mutableIntStateOf(0)
        private set

    fun openVideo(entry: VideoEntry) = openVideoQueue(listOf(entry))

    private var accountQueue = false

    private fun clearAccountQueue() {
        if (accountQueue) {
            video = null
            videoQueue = emptyList()
            accountQueue = false
        }
    }

    fun openVideoQueue(entries: List<VideoEntry>, fromAccount: Boolean = false) {
        val first = entries.firstOrNull() ?: return
        accountQueue = fromAccount
        videoQueue = entries
        showVideo++
        controller?.pause()
        video = first
    }

    fun play(list: List<Song>, at: Int = 0, shuffle: Boolean = false, append: Boolean = false) {
        if (list.isEmpty()) return
        val index = if (shuffle) list.indices.random() else at.coerceIn(list.indices)
        val selected = list[index]
        val youtubeId = selected.youtubeId
        if (youtubeId != null) {
            val ordered = if (shuffle) {
                listOf(selected) + list.filterIndexed { i, _ -> i != index }.shuffled()
            } else list.drop(index)
            openVideoQueue(ordered.mapNotNull { song ->
                song.youtubeId?.let { VideoEntry(it, "video", song.title, song.artist) }
            })
            if (list.any { it.youtubeId == null })
                notice("Playing the YouTube entries in this list.")
            return
        }
        val audio = list.filter { it.youtubeId == null }
        if (audio.size != list.size) notice("Playing the audio entries in this list.")
        val player = controller ?: return notice("Player is connecting. Try again.")
        task {
            store.db.withTransaction { list.forEach { dao.put(it) } }
            video = null
            val items = audio.map { it.media() }
            if (append) {
                player.addMediaItems(items)
                notice("Added to queue")
            } else {
                player.setMediaItems(items, audio.indexOf(selected), 0)
                player.shuffleModeEnabled = shuffle
                player.prepare()
                player.play()
            }
        }
    }

    fun toggle() {
        controller?.let {
            if (it.playWhenReady && it.playbackState != Player.STATE_ENDED) it.pause()
            else {
                if (it.playbackState == Player.STATE_ENDED) it.seekToDefaultPosition(0)
                it.prepare()
                it.play()
            }
        }
    }

    private suspend fun importAudioFiles(uris: List<Uri>): List<Song> {
        val songs = mutableListOf<Song>()
        for (uri in uris) {
            try {
                app.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                songs += store.import(uri)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Other selected documents may still be available.
            }
        }
        return songs
    }

    fun playAudioFiles(uris: List<Uri>) = task {
        val songs = importAudioFiles(uris)
        if (songs.isNotEmpty()) play(songs)
        if (songs.size < uris.size) notice("Could read ${songs.size} of ${uris.size} audio files.")
    }

    fun import(uris: List<Uri>) = task {
        val success = importAudioFiles(uris).size
        notice("Imported $success of ${uris.size} audio files")
    }

    fun download(song: Song) = task {
        dao.put(song)
        Offline.enqueue(app, song.id)
    }

    override fun onEvents(player: Player, events: Player.Events) {
        revision++
    }

    override fun onPlayerError(error: PlaybackException) {
        notice("Playback failed. Check your connection or reselect the local audio file.")
    }

    override fun onCleared() {
        controller?.removeListener(this)
        MediaController.releaseFuture(future)
        super.onCleared()
    }
}
