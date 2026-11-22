@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.maxrave.simpmusic.expect.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.UIKitView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.maxrave.domain.data.model.loginsync.LoginSyncHostState
import com.maxrave.simpmusic.ui.theme.typo
import com.maxrave.simpmusic.viewModel.LoginSyncHostViewModel
import com.maxrave.simpmusic.viewModel.LoginSyncSenderViewModel
import com.maxrave.simpmusic.viewModel.LoginSyncSenderViewModel.Step
import kotlinx.cinterop.CValue
import kotlinx.cinterop.ObjCAction
import org.koin.compose.viewmodel.koinViewModel
import platform.AVFoundation.AVAuthorizationStatusAuthorized
import platform.AVFoundation.AVAuthorizationStatusNotDetermined
import platform.AVFoundation.AVCaptureConnection
import platform.AVFoundation.AVCaptureDevice
import platform.AVFoundation.AVCaptureDeviceInput
import platform.AVFoundation.AVCaptureMetadataOutput
import platform.AVFoundation.AVCaptureMetadataOutputObjectsDelegateProtocol
import platform.AVFoundation.AVCaptureOutput
import platform.AVFoundation.AVCaptureSession
import platform.AVFoundation.AVCaptureVideoPreviewLayer
import platform.AVFoundation.AVLayerVideoGravityResizeAspectFill
import platform.AVFoundation.AVMediaTypeVideo
import platform.AVFoundation.AVMetadataMachineReadableCodeObject
import platform.AVFoundation.AVMetadataObjectTypeQRCode
import platform.AVFoundation.authorizationStatusForMediaType
import platform.AVFoundation.requestAccessForMediaType
import platform.CoreGraphics.CGRect
import platform.CoreImage.CIFilter
import platform.CoreImage.filterWithName
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.dataUsingEncoding
import platform.Foundation.setValue
import platform.QuartzCore.CATransaction
import platform.QuartzCore.kCATransactionDisableActions
import platform.UIKit.UIView
import platform.darwin.NSObject
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

/**
 * Login sync on iOS goes both ways (the protocol is SimpMusic's own, so the Android and Desktop
 * apps need no change):
 * - Receive: the iPhone shows a QR, like the Desktop app; the Android app scans it and sends.
 * - Send: the iPhone scans the Desktop app's QR and sends its own sign-ins, like the Android app.
 */
@Composable
actual fun LoginSyncDialog(onDismiss: () -> Unit) {
    var mode by remember { mutableStateOf<String?>(null) }
    when (mode) {
        "receive" -> ReceiveDialog(onDismiss)
        "send" -> SendDialog(onDismiss)
        else ->
            AlertDialog(
                onDismissRequest = onDismiss,
                title = { Text("Sincronizar login", style = typo().titleSmall) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedButton(onClick = { mode = "receive" }, modifier = Modifier.fillMaxWidth()) {
                            Text("Receber de um Android")
                        }
                        Text("O iPhone mostra um código; leia com o SimpMusic do Android.", style = typo().bodySmall)
                        OutlinedButton(onClick = { mode = "send" }, modifier = Modifier.fillMaxWidth()) {
                            Text("Enviar para o computador")
                        }
                        Text("Leia o código que o SimpMusic do computador mostra.", style = typo().bodySmall)
                    }
                },
                confirmButton = { TextButton(onClick = onDismiss) { Text("Cancelar", color = LocalContentColor.current) } },
            )
    }
}

@Composable
private fun ReceiveDialog(onDismiss: () -> Unit) {
    val viewModel: LoginSyncHostViewModel = koinViewModel()
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.open() }
    DisposableEffect(viewModel) { onDispose { viewModel.close() } }
    val canRestart =
        state is LoginSyncHostState.Expired || state is LoginSyncHostState.NoNetwork ||
            state is LoginSyncHostState.Failed || state is LoginSyncHostState.Rejected
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Receber login do Android", style = typo().titleSmall) },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when (val s = state) {
                    LoginSyncHostState.Starting -> CircularProgressIndicator()
                    is LoginSyncHostState.Waiting -> {
                        QrCode(s.invite, Modifier.size(240.dp))
                        Text(
                            "No Android: Ajustes → Sincronizar login, e leia este código. Os dois aparelhos precisam estar na mesma rede Wi-Fi.",
                            style = typo().bodyMedium,
                            textAlign = TextAlign.Center,
                        )
                        if (s.addresses.size > 1) {
                            Text("Se não conectar, escolha outro endereço:", style = typo().bodySmall)
                            s.addresses.forEach { address ->
                                Row(
                                    Modifier.fillMaxWidth().clickable { viewModel.select(address) }.padding(vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    RadioButton(selected = address == s.selected, onClick = null)
                                    Text("  ${address.ip}  ${address.interfaceName}", style = typo().bodyMedium)
                                }
                            }
                        }
                    }
                    LoginSyncHostState.Connected -> {
                        CircularProgressIndicator()
                        Text("Android conectado. Escolha no Android o que enviar.", textAlign = TextAlign.Center)
                    }
                    is LoginSyncHostState.Done -> Text("Recebido: ${s.services.joinToString { it.label }}. Pronto!")
                    LoginSyncHostState.Expired -> Text("O código expirou.")
                    LoginSyncHostState.NoNetwork -> Text("Conecte o iPhone ao Wi-Fi e tente de novo.")
                    is LoginSyncHostState.Failed -> Text("Não foi possível começar: ${s.message}")
                    is LoginSyncHostState.Rejected -> Text("Não deu para receber: ${s.reason}", textAlign = TextAlign.Center)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(if (state is LoginSyncHostState.Done) "OK" else "Cancelar", color = LocalContentColor.current)
            }
        },
        dismissButton =
            if (canRestart) {
                { TextButton(onClick = viewModel::open) { Text("Novo código", color = LocalContentColor.current) } }
            } else {
                null
            },
    )
}

@Composable
private fun SendDialog(onDismiss: () -> Unit) {
    val viewModel: LoginSyncSenderViewModel = koinViewModel()
    val ui by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) {
        when (AVCaptureDevice.authorizationStatusForMediaType(AVMediaTypeVideo)) {
            AVAuthorizationStatusAuthorized -> viewModel.open(hasCamera = true)
            AVAuthorizationStatusNotDetermined -> {
                viewModel.open(hasCamera = false)
                AVCaptureDevice.requestAccessForMediaType(AVMediaTypeVideo) { granted ->
                    dispatch_async(dispatch_get_main_queue()) { viewModel.onCameraPermission(granted, blocked = !granted) }
                }
            }
            else -> {
                viewModel.open(hasCamera = false)
                viewModel.onCameraPermission(granted = false, blocked = true)
            }
        }
    }
    DisposableEffect(viewModel) { onDispose { viewModel.close() } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Enviar login para o computador", style = typo().titleSmall) },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when (val step = ui.step) {
                    Step.Loading, Step.Connecting, Step.Sending -> CircularProgressIndicator()
                    Step.NothingSignedIn -> Text("Este iPhone ainda não entrou em nenhuma conta.")
                    is Step.NeedsCamera ->
                        Text(
                            if (step.blocked) "Permita a câmera em Ajustes do iPhone → SimpMusic." else "Permita a câmera para ler o código.",
                            textAlign = TextAlign.Center,
                        )
                    Step.NoCamera -> Text("Câmera indisponível.")
                    Step.Scanning -> {
                        QrScannerView(Modifier.fillMaxWidth().height(280.dp).clip(RoundedCornerShape(12.dp))) { viewModel.onScanned(it) }
                        Text("No computador: Ajustes → Sincronizar login. Aponte para o código.", textAlign = TextAlign.Center, style = typo().bodySmall)
                    }
                    is Step.Trust -> Text("Confiar em ${step.desktop.name} (${step.desktop.os})?", textAlign = TextAlign.Center)
                    is Step.Choose -> {
                        Text("Enviar para ${step.desktop.name}:")
                        ui.signedIn.forEach { service ->
                            Row(Modifier.fillMaxWidth().clickable { viewModel.toggle(service) }, verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(checked = service in ui.selected, onCheckedChange = { viewModel.toggle(service) })
                                Text(service.label)
                            }
                        }
                    }
                    is Step.Waiting -> Text("Confirme no computador ${step.desktop.name}.")
                    is Step.Declined -> Text("${step.desktop.name} recusou.")
                    is Step.Done -> Text("Enviado para ${step.desktop.name}: ${step.services.joinToString { it.label }}.")
                    is Step.Failed -> Text("Não deu certo (${step.reason}). ${step.detail.orEmpty()}", textAlign = TextAlign.Center)
                }
            }
        },
        confirmButton = {
            when (val step = ui.step) {
                is Step.Trust -> TextButton(onClick = viewModel::trust) { Text("Confiar", color = LocalContentColor.current) }
                is Step.Choose ->
                    TextButton(onClick = viewModel::send, enabled = ui.selected.isNotEmpty()) { Text("Enviar", color = LocalContentColor.current) }
                is Step.Failed, is Step.Declined ->
                    TextButton(onClick = { viewModel.retry(hasCamera = true) }) { Text("Tentar de novo", color = LocalContentColor.current) }
                else -> TextButton(onClick = onDismiss) { Text(if (step is Step.Done) "OK" else "Cancelar", color = LocalContentColor.current) }
            }
        },
        dismissButton = {
            if (ui.step is Step.Trust || ui.step is Step.Choose || ui.step is Step.Failed || ui.step is Step.Declined) {
                TextButton(onClick = onDismiss) { Text("Cancelar", color = LocalContentColor.current) }
            }
        },
    )
}

/** Dark modules on white (what scanners expect), from CoreImage's QR generator, scaled up crisply. */
@Composable
private fun QrCode(
    text: String,
    modifier: Modifier = Modifier,
) {
    val image = remember(text) { qrImage(text) }
    UIKitView(
        factory = {
            platform.UIKit.UIImageView().apply {
                this.image = image
                contentMode = platform.UIKit.UIViewContentMode.UIViewContentModeScaleAspectFit
                layer.magnificationFilter = platform.QuartzCore.kCAFilterNearest
                backgroundColor = platform.UIKit.UIColor.whiteColor
            }
        },
        modifier = modifier.clip(RoundedCornerShape(12.dp)).background(Color.White).padding(8.dp),
    )
}

private fun qrImage(text: String): platform.UIKit.UIImage? {
    val filter = CIFilter.filterWithName("CIQRCodeGenerator") ?: return null
    val data = (text as NSString).dataUsingEncoding(NSUTF8StringEncoding) ?: return null
    filter.setValue(data, forKey = "inputMessage")
    filter.setValue("M", forKey = "inputCorrectionLevel")
    val output = filter.outputImage ?: return null
    val scaled = output.imageByApplyingTransform(platform.CoreGraphics.CGAffineTransformMakeScale(12.0, 12.0))
    return platform.UIKit.UIImage.imageWithCIImage(scaled)
}

/** Camera preview that reports the first QR it reads (AVFoundation's own detector). */
@Composable
private fun QrScannerView(
    modifier: Modifier,
    onCode: (String) -> Unit,
) {
    val scanner = remember { QrScanner(onCode) }
    DisposableEffect(scanner) { onDispose { scanner.stop() } }
    UIKitView(factory = { scanner.view }, modifier = modifier)
}

private class QrScanner(
    private val onCode: (String) -> Unit,
) : NSObject(),
    AVCaptureMetadataOutputObjectsDelegateProtocol {
    private val session = AVCaptureSession()
    private val preview = AVCaptureVideoPreviewLayer(session = session)
    val view: UIView =
        object : UIView(frame = platform.CoreGraphics.CGRectMake(0.0, 0.0, 0.0, 0.0)) {
            override fun layoutSubviews() {
                super.layoutSubviews()
                CATransaction.begin()
                CATransaction.setValue(true, kCATransactionDisableActions)
                preview.frame = bounds
                CATransaction.commit()
            }
        }

    init {
        preview.videoGravity = AVLayerVideoGravityResizeAspectFill
        view.layer.addSublayer(preview)
        val device = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)
        val input = device?.let { AVCaptureDeviceInput.deviceInputWithDevice(it, null) }
        if (input != null && session.canAddInput(input)) {
            session.addInput(input)
            val output = AVCaptureMetadataOutput()
            if (session.canAddOutput(output)) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(this, dispatch_get_main_queue())
                output.metadataObjectTypes = listOf(AVMetadataObjectTypeQRCode)
            }
            platform.darwin.dispatch_async(platform.darwin.dispatch_get_global_queue(0, 0u)) { session.startRunning() }
        }
    }

    fun stop() {
        platform.darwin.dispatch_async(platform.darwin.dispatch_get_global_queue(0, 0u)) { session.stopRunning() }
    }

    override fun captureOutput(
        output: AVCaptureOutput,
        didOutputMetadataObjects: List<*>,
        fromConnection: AVCaptureConnection,
    ) {
        val code = didOutputMetadataObjects.firstNotNullOfOrNull { (it as? AVMetadataMachineReadableCodeObject)?.stringValue } ?: return
        onCode(code)
    }
}

