package com.maxrave.simpmusic.expect.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect

// Login sync moves sign-ins from the Android app to the Desktop app over a QR-paired local link
// (core/service/loginSync is Android + JVM only). There is nothing to pair with on iOS, so the
// dialog closes itself; Settings never offers it there.
@Composable
actual fun LoginSyncDialog(onDismiss: () -> Unit) {
    LaunchedEffect(Unit) { onDismiss() }
}
