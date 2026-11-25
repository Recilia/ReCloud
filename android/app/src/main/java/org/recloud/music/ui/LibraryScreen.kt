package org.recloud.music.ui

import androidx.activity.compose.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.recloud.music.viewmodel.MusicModel

@Composable
fun LibraryScreen(vm: MusicModel, selectPlaylist: (String) -> Unit) {
    val songs by remember { vm.dao.songs() }.collectAsStateWithLifecycle(emptyList())
    val mixes by remember { vm.dao.mixes() }.collectAsStateWithLifecycle(emptyList())
    val stars by remember { vm.dao.stars() }.collectAsStateWithLifecycle(emptyList())
    val stats by remember { vm.dao.stats() }.collectAsStateWithLifecycle(emptyList())
    val downloads by remember { vm.dao.downloads() }.collectAsStateWithLifecycle(emptyList())
    val picker =
        rememberLauncherForActivityResult(
            ActivityResultContracts.OpenMultipleDocuments(),
            vm::import,
        )
    var section by rememberSaveable { mutableStateOf("Songs") }
    var selected by rememberSaveable { mutableStateOf("") }
    var dialog by rememberSaveable { mutableStateOf("") }
    var name by rememberSaveable { mutableStateOf("") }
    val mix = mixes.find { it.id == selected }
    val songMap = remember(songs) { songs.associateBy { it.id } }
    val ranked =
        remember(stats) {
            stats
                .groupBy { it.song }
                .mapValues { (_, v) -> v.sumOf { it.starts } }
                .toList()
                .sortedByDescending { it.second }
        }
    val list =
        when {
            mix != null -> mix.ids().mapNotNull(songMap::get)
            section == "Favorites" -> stars.mapNotNull { songMap[it.song] }
            section == "Recents" -> stats.distinctBy { it.song }.mapNotNull { songMap[it.song] }
            section == "Offline" -> downloads.mapNotNull { songMap[it.song] }
            section == "Songs" -> songs
            else -> emptyList()
        }
    BackHandler(selected.isNotEmpty()) { selected = "" }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        item {
            if (mix != null) TextButton({ selected = "" }) { Text("‹ Playlists") }
            Heading(mix?.name ?: "Library")
            if (mix == null) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button({ picker.launch(arrayOf("audio/*")) }) { Text("Import audio") }
                    OutlinedButton({
                        dialog = "Create"
                        name = ""
                    }) {
                        Text("New playlist")
                    }
                }
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    listOf("Songs", "Playlists", "Favorites", "Recents", "Offline", "Stats")
                        .forEach { s ->
                            FilterChip(section == s, { section = s }, label = { Text(s) })
                        }
                }
            } else
                Row {
                    TextButton({
                        name = mix.name
                        dialog = "Rename"
                    }) {
                        Text("Rename")
                    }
                    TextButton({ dialog = "Delete" }) { Text("Delete") }
                }
            PlayActions(list, vm)
        }
        if (section == "Playlists" && mix == null) {
            if (mixes.isEmpty())
                item { Text("Create a playlist, then add tracks from their song menus.") }
            items(mixes) { p -> Entry(p.name, "${p.ids().size} tracks") { selected = p.id } }
            accountPlaylistRows(vm, selectPlaylist)
        } else if (section == "Stats" && mix == null) {
            item {
                Heading("Listening time")
                Text(time(stats.sumOf { it.millis }) + " · " + stats.sumOf { it.starts } + " plays")
                Heading("Most played")
            }
            items(ranked.take(30)) { (id, count) ->
                songMap[id]?.let { s ->
                    Entry(s.title, "$count plays · ${s.artist}") { vm.play(listOf(s)) }
                }
            }
            item { Heading("Top artists") }
            val artists =
                ranked
                    .groupBy { songMap[it.first]?.artist.orEmpty() }
                    .mapValues { it.value.sumOf { p -> p.second } }
                    .toList()
                    .sortedByDescending { it.second }
            items(artists.take(20)) { (artist, count) ->
                Text("${artist.ifBlank{"Unknown artist"}} · $count plays")
            }
        } else {
            if (list.isEmpty())
                item {
                    Text(
                        when (section) {
                            "Offline" -> "Download a licensed recording from its song menu."
                            "Favorites" -> "Favorite a song from its menu to save it here."
                            "Recents" -> "Your listening history will appear here."
                            else -> "Add music using Import audio or a song menu."
                        }
                    )
                }
            itemsIndexed(list) { i, song ->
                SongRow(
                    song,
                    vm,
                    { vm.play(list, i) },
                    if (mix == null) null
                    else {
                        {
                            vm.task { vm.store.member(mix.id, song, false) }
                            Unit
                        }
                    },
                )
            }
        }
    }
    if (dialog != "")
        AlertDialog(
            onDismissRequest = { dialog = "" },
            title = { Text("$dialog playlist") },
            text = {
                if (dialog == "Delete") Text("Delete “${mix?.name.orEmpty()}”?")
                else
                    OutlinedTextField(
                        name,
                        { name = it },
                        singleLine = true,
                        label = { Text("Playlist name") },
                    )
            },
            confirmButton = {
                TextButton(
                    enabled = dialog == "Delete" || name.isNotBlank(),
                    onClick = {
                        when (dialog) {
                            "Create" -> vm.task { vm.store.changeMix(null, name) }
                            "Rename" ->
                                mix?.let {
                                    vm.task {
                                        vm.store.changeMix(it.id) { p -> p.copy(name = name) }
                                    }
                                }
                            "Delete" ->
                                mix?.let {
                                    vm.task {
                                        vm.store.changeMix(it.id) { p -> p.copy(deleted = true) }
                                    }
                                    selected = ""
                                }
                        }
                        dialog = ""
                    },
                ) {
                    Text(dialog)
                }
            },
            dismissButton = { TextButton({ dialog = "" }) { Text("Cancel") } },
        )
}
