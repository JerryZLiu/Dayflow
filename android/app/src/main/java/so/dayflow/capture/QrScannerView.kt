package so.dayflow.capture

import android.annotation.SuppressLint
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@SuppressLint("UnsafeOptInUsageError")
@Composable
fun QrScannerView(onResult: (String) -> Unit, onClose: () -> Unit) {
  val context = LocalContext.current
  val lifecycleOwner = LocalLifecycleOwner.current
  val previewView = remember { PreviewView(context) }
  val executor = remember { Executors.newSingleThreadExecutor() }
  val scanner = remember { BarcodeScanning.getClient() }
  val delivered = remember { AtomicBoolean(false) }

  DisposableEffect(lifecycleOwner) {
    val future = ProcessCameraProvider.getInstance(context)
    future.addListener({
      val provider = future.get()
      val preview = Preview.Builder().build().also {
        it.surfaceProvider = previewView.surfaceProvider
      }
      val analysis = ImageAnalysis.Builder()
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .build()
      analysis.setAnalyzer(executor) { proxy ->
        val mediaImage = proxy.image
        if (mediaImage == null || delivered.get()) {
          proxy.close()
          return@setAnalyzer
        }
        scanner.process(InputImage.fromMediaImage(mediaImage, proxy.imageInfo.rotationDegrees))
          .addOnSuccessListener { codes ->
            val value = codes.firstNotNullOfOrNull { it.rawValue }
            if (value != null && delivered.compareAndSet(false, true)) onResult(value)
          }
          .addOnCompleteListener { proxy.close() }
      }
      provider.unbindAll()
      provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
    }, ContextCompat.getMainExecutor(context))

    onDispose {
      runCatching { future.get().unbindAll() }
      scanner.close()
      executor.shutdown()
    }
  }

  Box(Modifier.fillMaxSize().background(Color.Black)) {
    AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
    IconButton(onClick = onClose, modifier = Modifier.align(Alignment.TopEnd)) {
      Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.close_scanner), tint = Color.White)
    }
  }
}
