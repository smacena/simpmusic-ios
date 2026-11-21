package com.maxrave.simpmusic.utils

import platform.UIKit.UIActivityViewController
import platform.UIKit.UIApplication
import platform.UIKit.UIViewController
import platform.UIKit.UIWindow
import platform.UIKit.UIWindowScene
import platform.UIKit.popoverPresentationController

/** The view controller currently on top, to present share sheets from. */
internal fun topViewController(): UIViewController? {
    val window =
        UIApplication.sharedApplication.connectedScenes
            .filterIsInstance<UIWindowScene>()
            .flatMap { scene -> scene.windows.filterIsInstance<UIWindow>() }
            .firstOrNull { it.isKeyWindow() }
            ?: UIApplication.sharedApplication.keyWindow
    var top = window?.rootViewController
    while (top?.presentedViewController != null) top = top.presentedViewController
    return top
}

/** Shows the system share sheet for [items] (strings, NSURLs, UIImages). */
internal fun presentShareSheet(items: List<Any>): Boolean {
    val presenter = topViewController() ?: return false
    val sheet = UIActivityViewController(activityItems = items, applicationActivities = null)
    // On iPad the sheet is a popover and needs an anchor, or UIKit throws.
    sheet.popoverPresentationController?.sourceView = presenter.view
    presenter.presentViewController(sheet, animated = true, completion = null)
    return true
}
