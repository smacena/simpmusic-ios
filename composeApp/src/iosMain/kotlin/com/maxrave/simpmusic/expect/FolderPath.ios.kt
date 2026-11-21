package com.maxrave.simpmusic.expect

import platform.Foundation.NSDocumentDirectory
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSUserDomainMask

// iOS apps have no shared Downloads folder. Documents is the app's own user-visible folder (it
// shows up in the Files app once UIFileSharingEnabled is set in Info.plist).
actual fun getDownloadFolderPath(): String =
    NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, true).firstOrNull() as? String
        ?: ""
