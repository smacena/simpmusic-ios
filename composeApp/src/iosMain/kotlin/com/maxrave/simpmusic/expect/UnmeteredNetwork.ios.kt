package com.maxrave.simpmusic.expect

import kotlinx.cinterop.ExperimentalForeignApi
import platform.Network.nw_path_get_status
import platform.Network.nw_path_is_constrained
import platform.Network.nw_path_is_expensive
import platform.Network.nw_path_monitor_create
import platform.Network.nw_path_monitor_set_queue
import platform.Network.nw_path_monitor_set_update_handler
import platform.Network.nw_path_monitor_start
import platform.Network.nw_path_status_satisfied
import platform.darwin.dispatch_get_global_queue
import platform.darwin.DISPATCH_QUEUE_PRIORITY_DEFAULT
import kotlin.concurrent.AtomicInt

/**
 * Wi-Fi / Ethernet, as opposed to mobile data or a hotspot. iOS answers through NWPathMonitor:
 * a path that is not "expensive" (cellular or a personal hotspot) and not "constrained" (Low Data
 * Mode) is unmetered. One monitor runs for the life of the app and keeps the last answer, so this
 * call is instant; until the first update arrives it answers false (the safe side for downloads).
 */
private val unmetered = AtomicInt(0)

@OptIn(ExperimentalForeignApi::class)
private val monitor by lazy {
    nw_path_monitor_create().also { m ->
        nw_path_monitor_set_update_handler(m) { path ->
            val ok = nw_path_get_status(path) == nw_path_status_satisfied && !nw_path_is_expensive(path) && !nw_path_is_constrained(path)
            unmetered.value = if (ok) 1 else 0
        }
        nw_path_monitor_set_queue(m, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0u))
        nw_path_monitor_start(m)
    }
}

/** Starts the monitor early (app start) so the first real question already has an answer. */
fun startNetworkMonitor() {
    monitor
}

actual fun isOnUnmeteredNetwork(): Boolean {
    monitor
    return unmetered.value == 1
}
