package com.maxrave.simpmusic.expect

import com.maxrave.simpmusic.utils.presentShareSheet
import platform.Foundation.NSURL
import platform.UIKit.UIApplication

actual fun openUrl(url: String) {
    val nsUrl = NSURL.URLWithString(url) ?: return
    UIApplication.sharedApplication.openURL(nsUrl, options = emptyMap<Any?, Any>(), completionHandler = null)
}

actual fun shareUrl(
    title: String,
    url: String,
) {
    presentShareSheet(listOf(url))
}
