package org.recloud.music

import android.app.Application
import androidx.room.Room
import java.io.File
import kotlinx.coroutines.flow.first
import okhttp3.Cache
import okhttp3.OkHttpClient
import org.recloud.music.database.Library
import org.recloud.music.network.ArchiveCatalog
import org.recloud.music.repository.Collection
import org.recloud.music.settings.Options

class ReCloud : Application() {
    val collection by lazy {
        Collection(this, Room.databaseBuilder(this, Library::class.java, "library.db").build())
    }
    val client by lazy {
        OkHttpClient.Builder().cache(Cache(File(cacheDir, "catalog"), 16L shl 20)).build()
    }
    val catalog by lazy {
        ArchiveCatalog(client) { options.values.first()["quality"] ?: "Balanced" }
    }
    val options by lazy { Options(this) }
}
