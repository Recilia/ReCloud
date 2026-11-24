package org.recloud.music.auth

import android.app.Activity
import android.content.Intent
import androidx.activity.result.IntentSenderRequest
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.recloud.music.network.field
import org.recloud.music.network.json

data class YouTubeLink(val title: String, val url: String)

interface AccountProvider {
    suspend fun playlists(token: String): List<YouTubeLink>
}

class YouTubeAccount(private val client: OkHttpClient) : AccountProvider {
    fun authorize(
        activity: Activity,
        account: android.accounts.Account,
        consent: (IntentSenderRequest) -> Unit,
        ready: (String) -> Unit,
        fail: (String) -> Unit,
    ) {
        val request =
            AuthorizationRequest.builder()
                .setAccount(account)
                .setRequestedScopes(
                    listOf(Scope("https://www.googleapis.com/auth/youtube.readonly"))
                )
                .build()
        Identity.getAuthorizationClient(activity)
            .authorize(request)
            .addOnSuccessListener {
                val pending = it.pendingIntent
                if (it.hasResolution() && pending != null)
                    consent(IntentSenderRequest.Builder(pending).build())
                else it.accessToken?.let(ready) ?: fail("Google did not grant playlist access.")
            }
            .addOnFailureListener { fail(authorizationFailure(it)) }
    }

    fun finish(
        activity: Activity,
        intent: Intent?,
        ready: (String) -> Unit,
        fail: (String) -> Unit,
    ) {
        if (intent == null) {
            fail("Sign-in canceled.")
            return
        }
        runCatching {
                requireNotNull(
                    Identity.getAuthorizationClient(activity)
                        .getAuthorizationResultFromIntent(intent)
                        .accessToken
                )
            }
            .onSuccess(ready)
            .onFailure { fail(authorizationFailure(it)) }
    }

    override suspend fun playlists(token: String): List<YouTubeLink> {
        val result = mutableListOf<YouTubeLink>()
        var page = ""
        do {
            val url =
                "https://www.googleapis.com/youtube/v3/playlists"
                    .toHttpUrl()
                    .newBuilder()
                    .addQueryParameter("part", "snippet")
                    .addQueryParameter("mine", "true")
                    .addQueryParameter("maxResults", "50")
                    .apply { if (page.isNotBlank()) addQueryParameter("pageToken", page) }
                    .build()
            val root =
                client.json(
                    Request.Builder()
                        .url(url)
                        .header("Authorization", "Bearer $token")
                        .header("Cache-Control", "no-store")
                        .build()
                )
            root.getValue("items").jsonArray.forEach { value ->
                val item = value.jsonObject
                result +=
                    YouTubeLink(
                        item.getValue("snippet").jsonObject.field("title"),
                        "https://www.youtube.com/playlist?list=" + item.field("id"),
                    )
            }
            page = root.field("nextPageToken")
        } while (page.isNotEmpty() && result.size < 1000)
        return result
    }
}

private fun authorizationFailure(error: Throwable): String {
    val status = (error as? com.google.android.gms.common.api.ApiException)?.status
    val code = status?.statusCode
    return when (code) {
        8 -> internalAuthorizationError(status.statusMessage.orEmpty())
        10 ->
            "Google rejected this app registration. Check the Android OAuth client package and signing certificate."
        7 -> "Google could not be reached. Check the network and try again."
        16,
        12501 -> "Google authorization was canceled."
        else ->
            "Google could not authorize playlist access (status ${code ?: "unknown"}). Check Play services and the OAuth consent settings."
    }
}

internal fun internalAuthorizationError(detail: String): String {
    val subcode = Regex("""\b\d{4,6}\b""").find(detail)?.value
    val label = if (subcode == null) "8" else "8/$subcode"
    return when {
        detail.contains("console", true) || detail.contains("configuration", true) ->
            "Google reports a project configuration error ($label). Verify this APK certificate and Android OAuth client in Google Cloud."
        detail.contains("network", true) ->
            "Google reports a network error ($label). Reconnect and try again."
        else -> "Google Play services returned an internal error ($label). Retry, then check the signing certificate and OAuth registration."
    }
}
internal fun playlistFailureMessage(error: Exception): String {
    val failure = error as? org.recloud.music.network.ServiceFailure
        ?: return if (error is java.io.IOException) "Could not reach YouTube. Check the connection and retry playlists."
        else "YouTube returned an unreadable playlist response."
    return when {
        failure.reasons.any { it in setOf("accessNotConfigured", "SERVICE_DISABLED") } -> "Enable YouTube Data API v3 in the OAuth client's Google Cloud project, then retry playlists."
        "youtubeSignupRequired" in failure.reasons -> "Open YouTube with this Google account and create a channel, then retry playlists."
        failure.status == 401 -> "YouTube rejected the access token. Connect your Google account again."
        failure.reasons.any { it.contains("quota", true) || it.contains("rateLimit", true) } -> "YouTube API quota or rate limit reached. Retry later."
        else -> "YouTube playlist request failed (HTTP ${failure.status}${failure.reasons.firstOrNull()?.let { ", $it" }.orEmpty()})."
    }
}