package com.maxrave.simpmusic

sealed class Platform {
    object Android : Platform()
    object iOS : Platform()
    object Desktop : Platform()

    fun osName(): String = when (this) {
        Android -> "android"
        iOS -> "iOS"
        Desktop -> desktopOsName() ?: "jvm"
    }
}

expect fun getPlatform(): Platform

/** `os.name` on the desktop JVM; null on platforms that have no such property. */
expect fun desktopOsName(): String?
