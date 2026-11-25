package org.recloud.music

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.*
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.recloud.music.network.VideoEntry
import org.recloud.music.ui.videoQueuePage

@RunWith(AndroidJUnit4::class)
class VideoQueueWebViewTest {
    @SuppressLint("SetJavaScriptEnabled")
    @Test
    fun longQueueCuesInOrderAndReportsTrackChanges() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val entries =
            (1..52).map { VideoEntry(it.toString().padStart(11, '0'), "video", "Track $it") }
        val changed = CountDownLatch(1)
        val script =
            """
                window.YT = {Player: function(element, config) {
                  const frame = document.createElement('iframe');
                  frame.id = element;
                  document.getElementById(element).replaceWith(frame);
                  document.body.style.height = '0px';
                  config.events.onReady({target: {cuePlaylist: function(ids) {
                    if (ids.length === 52 && ids[0] === '00000000001' && ids[51] === '00000000052'
                        && innerHeight > 0 && Math.abs(frame.getBoundingClientRect().height - innerHeight) <= 1) {
                      config.events.onStateChange({target: {getPlaylistIndex: function() { return 51; }}});
                    }
                  }}});
                }};
                onYouTubeIframeAPIReady();
            """
                .trimIndent()
        lateinit var view: WebView
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { activity ->
            view = WebView(activity)
            activity.setContentView(view, ViewGroup.LayoutParams(800, 450))
            view.settings.javaScriptEnabled = true
            view.webViewClient =
                object : WebViewClient() {
                    override fun shouldInterceptRequest(
                        view: WebView,
                        request: WebResourceRequest,
                    ): WebResourceResponse? {
                        if (request.url.toString() != "https://www.youtube.com/iframe_api")
                            return null
                        return WebResourceResponse(
                            "application/javascript",
                            "utf-8",
                            script.byteInputStream(),
                        )
                    }
                }
            view.webChromeClient =
                object : WebChromeClient() {
                    override fun onReceivedTitle(view: WebView, title: String?) {
                        if (title == "queue:51") changed.countDown()
                    }
                }
            view.loadDataWithBaseURL(
                "https://org.recloud.music/",
                videoQueuePage(entries),
                "text/html",
                "UTF-8",
                null,
            )
        }
        try {
            assertTrue("Expected a visible iframe and track 52", changed.await(20, TimeUnit.SECONDS))
        } finally {
            instrument.runOnMainSync {
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
            }
            scenario.close()
        }
    }
}
