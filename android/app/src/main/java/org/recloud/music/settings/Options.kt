package org.recloud.music.settings

import android.content.Context
import androidx.datastore.preferences.core.*
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.map

private val Context.settings by preferencesDataStore("preferences")

class Options(private val context: Context) {
    val values =
        context.settings.data.map { prefs ->
            prefs.asMap().mapKeys { it.key.name }.mapValues { it.value.toString() }
        }

    suspend fun set(key: String, value: String) {
        context.settings.edit { it[stringPreferencesKey(key)] = value }
    }
}
