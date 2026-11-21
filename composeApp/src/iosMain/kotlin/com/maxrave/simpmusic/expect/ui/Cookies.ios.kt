package com.maxrave.simpmusic.expect.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitView
import com.maxrave.logger.Logger
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.delay
import platform.Foundation.NSDate
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSHTTPCookieStorage
import platform.Foundation.NSURL
import platform.Foundation.NSURLRequest
import platform.Foundation.distantPast
import platform.WebKit.WKNavigation
import platform.WebKit.WKNavigationDelegateProtocol
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.NSObject

// Sign-in runs in a WKWebView, the iOS counterpart of Android's WebView. WebKit keeps its cookies
// in its own store (WKHTTPCookieStore, asynchronous), while WebViewCookieManager is synchronous —
// so after every finished page the WebKit cookies are mirrored into NSHTTPCookieStorage, and the
// manager reads from there.

/** Mobile Safari: Google refuses to sign in from user agents it takes for an embedded web view. */
private const val SAFARI_USER_AGENT =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"

private val webKitCookies get() = WKWebsiteDataStore.defaultDataStore().httpCookieStore

/** Copies WebKit's cookies into NSHTTPCookieStorage, then runs [then]. */
private fun mirrorWebKitCookies(then: () -> Unit) {
    webKitCookies.getAllCookies { cookies ->
        val storage = NSHTTPCookieStorage.sharedHTTPCookieStorage
        cookies?.filterIsInstance<NSHTTPCookie>()?.forEach { storage.setCookie(it) }
        then()
    }
}

private class IosCookieManager : WebViewCookieManager {
    override fun getCookie(url: String): String {
        val nsUrl = NSURL.URLWithString(url) ?: return ""
        return NSHTTPCookieStorage.sharedHTTPCookieStorage
            .cookiesForURL(nsUrl)
            .orEmpty()
            .filterIsInstance<NSHTTPCookie>()
            .joinToString("; ") { "${it.name}=${it.value}" }
    }

    override fun removeAllCookies() {
        val storage = NSHTTPCookieStorage.sharedHTTPCookieStorage
        storage.cookies.orEmpty().filterIsInstance<NSHTTPCookie>().forEach { storage.deleteCookie(it) }
        // Signing in again must start from a clean session in WebKit too.
        WKWebsiteDataStore.defaultDataStore().removeDataOfTypes(
            WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince = NSDate.distantPast,
            completionHandler = {},
        )
    }
}

actual fun createWebViewCookieManager(): WebViewCookieManager = IosCookieManager()

private class PageFinishedDelegate(
    private val onFinished: (String) -> Unit,
) : NSObject(),
    WKNavigationDelegateProtocol {
    override fun webView(
        webView: WKWebView,
        didFinishNavigation: WKNavigation?,
    ) {
        val url = webView.URL?.absoluteString ?: return
        mirrorWebKitCookies { onFinished(url) }
    }
}

@OptIn(ExperimentalForeignApi::class)
private fun newWebView(): WKWebView {
    val configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore()
    return WKWebView(frame = platform.CoreGraphics.CGRectMake(0.0, 0.0, 0.0, 0.0), configuration = configuration).apply {
        customUserAgent = SAFARI_USER_AGENT
    }
}

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun PlatformWebView(
    state: MutableState<WebViewState>,
    initUrl: String,
    aboveContent: @Composable (BoxScope.() -> Unit),
    clearCookies: Boolean,
    onPageFinished: (String) -> Unit,
) {
    val latestOnPageFinished = rememberUpdatedState(onPageFinished)
    // The delegate is held weakly by WKWebView, so it must be kept alive here.
    val delegate =
        remember {
            PageFinishedDelegate { url ->
                state.value = WebViewState.Finished
                latestOnPageFinished.value(url)
            }
        }
    val webView = remember { newWebView().apply { navigationDelegate = delegate } }
    LaunchedEffect(Unit) {
        if (clearCookies) createWebViewCookieManager().removeAllCookies()
        // removeDataOfTypes is asynchronous; give it a moment before the first request goes out.
        if (clearCookies) delay(300)
        NSURL.URLWithString(initUrl)?.let { webView.loadRequest(NSURLRequest.requestWithURL(it)) }
    }
    DisposableEffect(Unit) {
        onDispose {
            webView.stopLoading()
            webView.navigationDelegate = null
        }
    }
    Box(Modifier.fillMaxSize()) {
        UIKitView(factory = { webView }, modifier = Modifier.fillMaxSize())
        aboveContent()
    }
}

/** Reads the token Discord keeps in localStorage, the same snippet the Android WebView runs. */
private const val DISCORD_TOKEN_JS =
    "(function(){var i=document.createElement('iframe');document.body.appendChild(i);" +
        "return i.contentWindow.localStorage.token.slice(1,-1)})()"

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun DiscordWebView(
    state: MutableState<WebViewState>,
    aboveContent: @Composable (BoxScope.() -> Unit),
    onLoginDone: (token: String) -> Unit,
) {
    val latestOnLoginDone = rememberUpdatedState(onLoginDone)
    val webView = remember { newWebView() }
    LaunchedEffect(Unit) {
        NSURL.URLWithString("https://discord.com/login")?.let { webView.loadRequest(NSURLRequest.requestWithURL(it)) }
        // Discord is a single-page app: reaching /app after sign-in is a history push, not a
        // navigation, so no delegate callback fires. Watch the URL instead.
        var done = false
        while (!done) {
            delay(1000)
            val path = webView.URL?.path.orEmpty()
            if (path.endsWith("/app") || path.startsWith("/channels")) {
                webView.evaluateJavaScript(DISCORD_TOKEN_JS) { result, error ->
                    val token = result as? String
                    if (error != null || token.isNullOrEmpty()) {
                        Logger.w("DiscordWebView", "token not readable yet")
                    } else {
                        done = true
                        latestOnLoginDone.value(token)
                    }
                }
            }
        }
    }
    DisposableEffect(Unit) { onDispose { webView.stopLoading() } }
    Box(Modifier.fillMaxSize()) {
        UIKitView(factory = { webView }, modifier = Modifier.fillMaxSize())
        aboveContent()
    }
}
