package com.maxrave.simpmusic.expect.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect

// Library sync pairs a phone with the Desktop app over the local network (the loginSync
// transport, Android + JVM only). iOS has no transport for it yet, so the dialog closes itself.
@Composable
actual fun LibrarySyncDialog(onDismiss: () -> Unit) {
    LaunchedEffect(Unit) { onDismiss() }
}

// iOS does not let an app relaunch itself; synced settings simply apply on the next launch.
actual fun restartAfterSyncedSettings() = Unit
