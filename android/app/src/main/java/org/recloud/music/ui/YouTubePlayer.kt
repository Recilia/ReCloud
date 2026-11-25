package org.recloud.music.ui

import android.annotation.SuppressLint
import android.util.Log
import android.webkit.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.lazy.LazyColumn
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.recloud.music.R
import org.recloud.music.network.VideoEntry


private data class TransportState(val state: Int, val elapsed: Long, val duration: Long)

@SuppressLint("SetJavaScriptEnabled")
@Composable
internal fun YouTubePlayer(
    queue: List<VideoEntry>,
    position: Int,
    onPosition: (Int) -> Unit,
    details: @Composable () -> Unit,
) {
    if (queue.isEmpty()) return
    val lifecycle by
        LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsStateWithLifecycle(
            minActiveState = Lifecycle.State.CREATED
        )
    var attempt by remember { mutableIntStateOf(0) }
    val open = openLink()
    key(attempt, lifecycle.isAtLeast(Lifecycle.State.RESUMED)) {
        var web by remember { mutableStateOf<WebView?>(null) }
        var transport by remember { mutableStateOf<TransportState?>(null) }
        var error by remember { mutableStateOf("") }
        var timedOut by remember { mutableStateOf(false) }
        var shuffleOn by remember { mutableStateOf(false) }
        var showQueue by remember { mutableStateOf(false) }
        var playbackOrder by remember { mutableStateOf(emptyList<String>()) }
        var playOrderIndex by remember { mutableStateOf(-1) }
        var drag by remember(position) { mutableStateOf<Float?>(null) }
        val updateIndex by rememberUpdatedState(onPosition)
        if (lifecycle.isAtLeast(Lifecycle.State.RESUMED)) {
            Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).heightIn(min = 200.dp)) {
                AndroidView(
                    modifier = Modifier.matchParentSize(),
                    factory = { context ->
                        WebView(context).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            settings.allowFileAccess = false
                            settings.allowContentAccess = false
                            // Compose transport buttons deliver the user's play gesture outside
                            // WebView.
                            settings.mediaPlaybackRequiresUserGesture = false
                            webChromeClient =
                                object : WebChromeClient() {
                                    override fun onReceivedTitle(view: WebView, title: String?) {
                                        if (title?.startsWith("queue:") == true) {
                                            title
                                                .substringAfter(':')
                                                .toIntOrNull()
                                                ?.takeIf { it in queue.indices }
                                            ?.let {
                                                error = ""
                                                updateIndex(it)
                                            }
                                        } else if (title?.startsWith("error:") == true) {
                                            val code =
                                                title.substringAfter(':').toIntOrNull() ?: return
                                            error =
                                                when (code) {
                                                    101,
                                                    150 ->
                                                        "The owner allows playback on YouTube only."
                                                    100 -> "This video is private or unavailable."
                                                    153 ->
                                                        "YouTube could not identify this app's player."
                                                    else ->
                                                        "YouTube could not play this video (error $code)."
                                                }
                                            Log.w("ReCloudPlayer", "YouTube player error $code")
                                        }
                                    }
                                }
                            webViewClient =
                                object : WebViewClient() {
                                    override fun shouldOverrideUrlLoading(
                                        view: WebView,
                                        request: WebResourceRequest,
                                    ): Boolean {
                                        if (!request.isForMainFrame) return false
                                        if (request.url.scheme == "https")
                                            open(request.url.toString())
                                        return true
                                    }

                                    override fun onReceivedError(
                                        view: WebView,
                                        request: WebResourceRequest,
                                        failure: WebResourceError,
                                    ) {
                                        if (
                                            request.isForMainFrame ||
                                                request.url.toString() ==
                                                    "https://www.youtube.com/iframe_api"
                                        ) {
                                            error =
                                                "Could not load the YouTube player. Check your connection and retry."
                                            Log.w(
                                                "ReCloudPlayer",
                                                "WebView load error ${failure.errorCode}",
                                            )
                                        }
                                    }
                                }
                            loadDataWithBaseURL(
                                "https://${context.packageName}/",
                                videoQueuePage(queue, position),
                                "text/html",
                                "UTF-8",
                                null,
                            )
                            web = this
                        }
                    },
                    onRelease = {
                        web = null
                        it.stopLoading()
                        it.destroy()
                    },
                )
            }
        }
        LaunchedEffect(web, showQueue) {
            val view = web ?: return@LaunchedEffect
            while (true) {
                view.evaluateJavascript("window.transportSnapshot ? transportSnapshot($showQueue) : null") {
                    value ->
                    if (web !== view || value == null || !value.startsWith("["))
                        return@evaluateJavascript
                    val data = JSONArray(value)
                    playOrderIndex = data.optInt(3, -1)
                    data.optJSONArray(4)?.let { ids ->
                        playbackOrder = List(ids.length()) { index -> ids.optString(index) }
                    }
                    transport = TransportState(data.optInt(0), data.optLong(1), data.optLong(2))
                }
                delay(500)
            }
        }
        LaunchedEffect(web, transport != null) {
            timedOut = false
            if (web != null && transport == null) {
                delay(15000)
                timedOut = true
            }
        }
        details()
        if (error.isNotEmpty() || timedOut) {
            Text(error.ifEmpty { "YouTube did not finish loading. Check your connection and retry." })
            TextButton({ attempt++ }) { Text("Retry player") }
        }
        val duration = transport?.duration ?: 0L
        val elapsed = transport?.elapsed?.coerceIn(0L, duration) ?: 0L
        val ready = transport != null
        val playing = transport?.state in listOf(1, 3)
        fun command(script: String) {
            web?.evaluateJavascript(script, null)
        }
        Slider(
            value = drag ?: elapsed.toFloat(),
            onValueChange = { drag = it },
            onValueChangeFinished = {
                drag?.let { command("player.seekTo(${it.toLong()} / 1000, true)") }
                drag = null
            },
            valueRange = 0f..duration.coerceAtLeast(1).toFloat(),
            enabled = ready && duration > 0,
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(time(drag?.toLong() ?: elapsed))
            Text(time(duration))
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Transport(
                R.drawable.shuffle,
                if (shuffleOn) "Turn shuffle off" else "Turn shuffle on",
                shuffleOn,
                ready && queue.size > 1 && playOrderIndex >= 0,
            ) {
                shuffleOn = !shuffleOn
                command("player.setShuffle($shuffleOn)")
            }
            Transport(
                icon = R.drawable.prev,
                label = "Previous",
                enabled = ready && playOrderIndex > 0,
            ) {
                command("player.previousVideo()")
            }
            Transport(
                if (playing) R.drawable.pause else R.drawable.play,
                if (playing) "Pause" else "Play",
                selected = true,
                enabled = ready,
            ) {
                command(if (playing) "player.pauseVideo()" else "player.playVideo()")
            }
            Transport(R.drawable.next, "Next", enabled = ready && playOrderIndex in 0 until queue.lastIndex) {
                command("player.nextVideo()")
            }
            Transport (
                R.drawable.repeat,
                if (transport?.state == 5) "Turn loop off" else "Turn loop on",
                transport?.state == 5,
                ready && queue.size > 1 && playOrderIndex >= 0,
            ) {
                command("player.setLoop(${transport?.state != 5})")
            }
        }
        TextButton(
            onClick = {
                playbackOrder = emptyList()
                showQueue = !showQueue
            },
            enabled = ready,
        ) {
            Text(if (showQueue) "Hide song queue" else "View song queue")
        }

        if (showQueue) {
            Text("Up next", style = MaterialTheme.typography.titleMedium)

            val orderedSongs = remember(queue, playbackOrder) {
                val songsById = queue.groupBy { it.id }
                    .mapValues { (_, songs) -> ArrayDeque(songs) }

                playbackOrder.map { id -> songsById[id]?.removeFirstOrNull() }
            }

            when {
                queue.size == 1 -> Text("No more songs in this queue.")
                orderedSongs.isEmpty() || playOrderIndex < 0 -> Text("Loading queue…")
                playOrderIndex >= orderedSongs.lastIndex -> Text("No more songs in this queue.")
                else -> {
                    val firstUpcoming = playOrderIndex + 1

                    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 280.dp)) {
                        items(orderedSongs.size - firstUpcoming) { offset ->
                            val song = orderedSongs[firstUpcoming + offset]
                            ListItem(
                                headlineContent = { Text(song?.title ?: "Unknown song") },
                                supportingContent = { Text(song?.artist.orEmpty()) },
                                leadingContent = { Text("${offset + 1}") },
                            )
                        }
                    }
                }
            }
        }
    }
}

internal fun videoQueuePage(queue: List<VideoEntry>, position: Int = 0): String {
    val ids =
        queue.joinToString(",") {
            require(it.id.matches(Regex("[A-Za-z0-9_-]{11}")))
            "'${it.id}'"
        }
    val index = position.coerceIn(queue.indices)
    return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>queue:$index</title>
        <style>html,body{margin:0;background:#000;overflow:hidden}#player{display:block;border:0}</style>
        </head><body><div id="player"></div><script>
        var player, ready = false;
        function sizePlayer() {
          const frame = document.getElementById('player');
          if (frame && innerHeight > 0) {
            frame.style.width = innerWidth + 'px';
            frame.style.height = innerHeight + 'px';
          }
        }
        window.addEventListener('resize', sizePlayer);
        if (window.visualViewport) visualViewport.addEventListener('resize', sizePlayer);
        function transportSnapshot(includeQueue) {
        if (!ready) return null;

        return [
            player.getPlayerState(),
            Math.round(player.getCurrentTime() * 1000) || 0,
            Math.round(player.getDuration() * 1000) || 0,
            player.getPlaylistIndex(),
            includeQueue ? (player.getPlaylist() || []) : null
        ];
        }
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width: innerWidth, height: Math.max(200, innerHeight), videoId: '${queue[index].id}',
            playerVars: {playsinline: 1, origin: location.origin},
            events: {
              onReady: function(event) {
                sizePlayer();
                if (${queue.size} > 1) event.target.cuePlaylist([$ids], $index);
                ready = true;
              },
                onStateChange: function(event) {
                const index = event.target.getPlaylistIndex();
                if (index < 0) return;

                const order = event.target.getPlaylist?.();
                const original = [$ids];
                let originalIndex = index;

                if (order && order[index]) {
                    const id = order[index];
                    // Count occurrences because a playlist can contain the same video twice.
                    let occurrence = order.slice(0, index + 1).filter(item => item === id).length;
                    originalIndex = original.findIndex(item => item === id && --occurrence === 0);
                }

                if (originalIndex >= 0) document.title = 'queue:' + originalIndex;
                },
              onError: function(event) { document.title = 'error:' + event.data; }
            }
          });
          sizePlayer();
        }
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
    """
        .trimIndent()
}
