package com.maxrave.simpmusic.expect.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import com.maxrave.logger.Logger
import com.maxrave.simpmusic.utils.iosDocumentsPath
import com.maxrave.simpmusic.utils.topViewController
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSData
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSURL
import platform.Foundation.NSUUID
import platform.Foundation.writeToFile
import platform.PhotosUI.PHPickerConfiguration
import platform.PhotosUI.PHPickerFilter
import platform.PhotosUI.PHPickerResult
import platform.PhotosUI.PHPickerViewController
import platform.PhotosUI.PHPickerViewControllerDelegateProtocol
import platform.UIKit.UIDocumentPickerDelegateProtocol
import platform.UIKit.UIDocumentPickerViewController
import platform.UniformTypeIdentifiers.UTTypeImage
import platform.UniformTypeIdentifiers.UTTypeItem
import platform.darwin.NSObject
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

// Pickers report a plain file path (or null when cancelled). Both pickers below hand back COPIES
// inside the app's own storage, so the path stays readable without security-scoped access.

/** UIKit holds picker delegates weakly; this keeps the active one alive until it reports. */
private var activeDelegate: NSObject? = null

private class DocumentPickerDelegate(
    private val onResult: (String?) -> Unit,
) : NSObject(),
    UIDocumentPickerDelegateProtocol {
    override fun documentPicker(
        controller: UIDocumentPickerViewController,
        didPickDocumentsAtURLs: List<*>,
    ) {
        val url = didPickDocumentsAtURLs.firstOrNull() as? NSURL
        onResult(url?.path)
        activeDelegate = null
    }

    override fun documentPickerWasCancelled(controller: UIDocumentPickerViewController) {
        onResult(null)
        activeDelegate = null
    }
}

private class PhotoPickerDelegate(
    private val onResult: (String?) -> Unit,
) : NSObject(),
    PHPickerViewControllerDelegateProtocol {
    @OptIn(BetaInteropApi::class)
    override fun picker(
        picker: PHPickerViewController,
        didFinishPicking: List<*>,
    ) {
        picker.dismissViewControllerAnimated(true, completion = null)
        val provider = (didFinishPicking.firstOrNull() as? PHPickerResult)?.itemProvider
        if (provider == null) {
            onResult(null)
            activeDelegate = null
            return
        }
        provider.loadDataRepresentationForTypeIdentifier(UTTypeImage.identifier) { data: NSData?, error ->
            val path =
                data?.let {
                    val target = "${NSTemporaryDirectory()}${NSUUID().UUIDString}.img"
                    if (it.writeToFile(target, atomically = true)) target else null
                }
            if (error != null) Logger.w("PhotoPicker", "could not load the picked image: ${error.localizedDescription}")
            dispatch_async(dispatch_get_main_queue()) {
                onResult(path)
                activeDelegate = null
            }
        }
    }
}

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun filePickerResult(onResultUri: (String?) -> Unit): FilePickerLauncher {
    val callback = rememberUpdatedState(onResultUri)
    return remember {
        object : FilePickerLauncher {
            override fun launch() {
                val presenter = topViewController() ?: return callback.value(null)
                val delegate = DocumentPickerDelegate { callback.value(it) }
                activeDelegate = delegate
                val picker = UIDocumentPickerViewController(forOpeningContentTypes = listOf(UTTypeItem), asCopy = true)
                picker.delegate = delegate
                presenter.presentViewController(picker, animated = true, completion = null)
            }
        }
    }
}

/**
 * iOS has no "choose where to save" step before writing: the file goes into the app's Documents
 * folder (visible in the Files app), and the caller then offers it through the share sheet.
 */
@Composable
actual fun fileSaverResult(
    fileName: String,
    mimeType: String,
    onResultUri: (String?) -> Unit,
): FilePickerLauncher {
    val callback = rememberUpdatedState(onResultUri)
    val name = rememberUpdatedState(fileName)
    return remember {
        object : FilePickerLauncher {
            override fun launch() = callback.value("${iosDocumentsPath()}/${name.value.replace("/", "_")}")
        }
    }
}

@Composable
actual fun photoPickerResult(onResultUri: (String?) -> Unit): PhotoPickerLauncher {
    val callback = rememberUpdatedState(onResultUri)
    return remember {
        object : PhotoPickerLauncher {
            override fun launch() {
                val presenter = topViewController() ?: return callback.value(null)
                val delegate = PhotoPickerDelegate { callback.value(it) }
                activeDelegate = delegate
                val configuration =
                    PHPickerConfiguration().apply {
                        filter = PHPickerFilter.imagesFilter
                        selectionLimit = 1
                    }
                val picker = PHPickerViewController(configuration)
                picker.delegate = delegate
                presenter.presentViewController(picker, animated = true, completion = null)
            }
        }
    }
}
