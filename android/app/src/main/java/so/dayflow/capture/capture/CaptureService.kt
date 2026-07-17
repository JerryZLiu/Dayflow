package so.dayflow.capture.capture

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import so.dayflow.capture.DayflowCaptureApp
import so.dayflow.capture.MainActivity
import so.dayflow.capture.R

class CaptureService : LifecycleService() {
  private var projection: MediaProjection? = null
  private var virtualDisplay: VirtualDisplay? = null
  private var imageReader: ImageReader? = null
  private val processing = AtomicBoolean(false)
  private val mainHandler = Handler(Looper.getMainLooper())
  private var paused = false
  private var lastCaptureAt = 0L
  private var sequence = 0L
  private var sessionId = UUID.randomUUID().toString()
  private lateinit var appReader: ForegroundAppReader
  private lateinit var privacy: PrivacyPreferences
  private val app by lazy { application as DayflowCaptureApp }

  private val screenReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      when (intent?.action) {
        Intent.ACTION_SCREEN_OFF -> setPaused(true, getString(R.string.screen_locked))
        Intent.ACTION_USER_PRESENT -> setPaused(false)
      }
    }
  }

  override fun onCreate() {
    super.onCreate()
    appReader = ForegroundAppReader(this)
    privacy = PrivacyPreferences(this)
    createChannel()
    registerReceiver(
      screenReceiver,
      IntentFilter().apply {
        addAction(Intent.ACTION_SCREEN_OFF)
        addAction(Intent.ACTION_USER_PRESENT)
      },
      RECEIVER_NOT_EXPORTED
    )
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      CaptureActions.START -> startProjection(intent)
      CaptureActions.PAUSE -> setPaused(true)
      CaptureActions.RESUME -> setPaused(false)
      CaptureActions.STOP -> stopCapture()
    }
    return Service.START_NOT_STICKY
  }

  private fun startProjection(intent: Intent) {
    if (projection != null) return
    startForegroundCapture()
    val resultCode = intent.getIntExtra(CaptureActions.EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
    val resultData = intent.getParcelableExtra(CaptureActions.EXTRA_RESULT_DATA, Intent::class.java)
    if (resultCode != Activity.RESULT_OK || resultData == null) {
      CaptureState.update(RecordingState.ERROR, getString(R.string.capture_permission_denied))
      stopSelf()
      return
    }

    val manager = getSystemService(MediaProjectionManager::class.java)
    projection = manager.getMediaProjection(resultCode, resultData).also { mediaProjection ->
      mediaProjection.registerCallback(object : MediaProjection.Callback() {
        override fun onStop() {
          stopCapture()
        }
      }, mainHandler)
    }
    sessionId = UUID.randomUUID().toString()
    sequence = 0
    createVirtualDisplay()
    CaptureState.update(RecordingState.RECORDING)
    updateNotification()
  }

  private fun createVirtualDisplay() {
    val windowManager = getSystemService(WindowManager::class.java)
    val bounds = windowManager.currentWindowMetrics.bounds
    val density = resources.displayMetrics.densityDpi
    imageReader = ImageReader.newInstance(
      bounds.width(), bounds.height(), PixelFormat.RGBA_8888, 2
    ).also { reader ->
      reader.setOnImageAvailableListener({ source -> onImageAvailable(source) }, mainHandler)
    }
    virtualDisplay = projection?.createVirtualDisplay(
      "DayflowCapture",
      bounds.width(),
      bounds.height(),
      density,
      DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
      imageReader?.surface,
      null,
      mainHandler
    )
  }

  private fun onImageAvailable(reader: ImageReader) {
    val image = reader.acquireLatestImage() ?: return
    val now = System.currentTimeMillis()
    val power = getSystemService(PowerManager::class.java)
    if (paused || !power.isInteractive || now - lastCaptureAt < CAPTURE_INTERVAL_MS ||
      !processing.compareAndSet(false, true)
    ) {
      image.close()
      return
    }
    lastCaptureAt = now
    lifecycleScope.launch(Dispatchers.Default) {
      try {
        processImage(image)
      } finally {
        image.close()
        processing.set(false)
      }
    }
  }

  private suspend fun processImage(image: Image) {
    val queuedBytes = app.database.captureDao().pendingByteCount()
    if (queuedBytes >= MAX_QUEUE_BYTES) {
      setPaused(true, getString(R.string.queue_limit_reached))
      return
    }

    val foregroundApp = appReader.current()
    val blocked = privacy.isBlocked(foregroundApp)
    val source = image.toBitmap()
    val scaled = scaleForUpload(source)
    if (source !== scaled) source.recycle()
    val captureKind: String
    val output = if (blocked) {
      captureKind = "redacted"
      scaled.recycle()
      privatePlaceholder(image.width, image.height)
    } else if (scaled.isNearlyBlack()) {
      captureKind = "unavailable"
      scaled.recycle()
      privatePlaceholder(image.width, image.height, getString(R.string.capture_unavailable))
    } else {
      captureKind = "image"
      scaled
    }

    sequence += 1
    app.repository.enqueue(
      bitmap = output,
      sessionId = sessionId,
      sequence = sequence,
      foregroundAppId = foregroundApp?.packageName,
      foregroundAppName = foregroundApp?.label,
      captureKind = captureKind,
      orientation = if (output.height >= output.width) "portrait" else "landscape_left"
    )
    output.recycle()
  }

  private fun Image.toBitmap(): Bitmap {
    val plane = planes[0]
    val buffer = plane.buffer
    val pixelStride = plane.pixelStride
    val rowStride = plane.rowStride
    val rowPadding = rowStride - pixelStride * width
    val padded = Bitmap.createBitmap(
      width + rowPadding / pixelStride,
      height,
      Bitmap.Config.ARGB_8888
    )
    padded.copyPixelsFromBuffer(buffer)
    val cropped = Bitmap.createBitmap(padded, 0, 0, width, height)
    if (cropped !== padded) padded.recycle()
    return cropped
  }

  private fun scaleForUpload(bitmap: Bitmap): Bitmap {
    val longest = maxOf(bitmap.width, bitmap.height)
    if (longest <= 1600) return bitmap
    val ratio = 1600f / longest
    return Bitmap.createScaledBitmap(
      bitmap,
      (bitmap.width * ratio).toInt().coerceAtLeast(2),
      (bitmap.height * ratio).toInt().coerceAtLeast(2),
      true
    )
  }

  private fun privatePlaceholder(
    width: Int,
    height: Int,
    text: String = getString(R.string.private_app_hidden)
  ): Bitmap {
    val portrait = height >= width
    val targetWidth = if (portrait) 720 else 1280
    val targetHeight = if (portrait) 1600 else 720
    return Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888).also { bitmap ->
      Canvas(bitmap).apply {
        drawColor(Color.rgb(238, 238, 235))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
          color = Color.rgb(80, 80, 76)
          textSize = 34f
          textAlign = Paint.Align.CENTER
        }
        drawText(text, targetWidth / 2f, targetHeight / 2f, paint)
      }
    }
  }

  private fun Bitmap.isNearlyBlack(): Boolean {
    var dark = 0
    var total = 0
    val stepX = (width / 16).coerceAtLeast(1)
    val stepY = (height / 24).coerceAtLeast(1)
    for (y in 0 until height step stepY) {
      for (x in 0 until width step stepX) {
        val color = getPixel(x, y)
        if (Color.red(color) + Color.green(color) + Color.blue(color) < 30) dark++
        total++
      }
    }
    return total > 0 && dark.toFloat() / total > 0.97f
  }

  private fun setPaused(value: Boolean, message: String? = null) {
    paused = value
    CaptureState.update(if (value) RecordingState.PAUSED else RecordingState.RECORDING, message)
    updateNotification()
  }

  private fun stopCapture() {
    virtualDisplay?.release()
    virtualDisplay = null
    imageReader?.close()
    imageReader = null
    val activeProjection = projection
    projection = null
    activeProjection?.stop()
    CaptureState.update(RecordingState.STOPPED)
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf()
  }

  override fun onDestroy() {
    runCatching { unregisterReceiver(screenReceiver) }
    virtualDisplay?.release()
    imageReader?.close()
    projection = null
    CaptureState.update(RecordingState.STOPPED)
    super.onDestroy()
  }

  private fun startForegroundCapture() {
    ServiceCompat.startForeground(
      this,
      NOTIFICATION_ID,
      notification(),
      ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
    )
  }

  private fun updateNotification() {
    getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
  }

  private fun notification(): Notification {
    val openIntent = PendingIntent.getActivity(
      this,
      0,
      Intent(this, MainActivity::class.java),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
    val toggleAction = if (paused) CaptureActions.RESUME else CaptureActions.PAUSE
    val toggleLabel = getString(if (paused) R.string.resume_capture else R.string.pause_capture)
    val toggleIntent = PendingIntent.getService(
      this,
      1,
      Intent(this, CaptureService::class.java).setAction(toggleAction),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
    val stopIntent = PendingIntent.getService(
      this,
      2,
      Intent(this, CaptureService::class.java).setAction(CaptureActions.STOP),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setSmallIcon(R.drawable.ic_dayflow)
      .setContentTitle(getString(if (paused) R.string.capture_notification_paused else R.string.capture_notification_active))
      .setContentText(getString(R.string.capture_notification_detail))
      .setOngoing(true)
      .setContentIntent(openIntent)
      .addAction(0, toggleLabel, toggleIntent)
      .addAction(0, getString(R.string.stop_capture), stopIntent)
      .build()
  }

  private fun createChannel() {
    getSystemService(NotificationManager::class.java).createNotificationChannel(
      NotificationChannel(CHANNEL_ID, getString(R.string.capture_channel), NotificationManager.IMPORTANCE_LOW)
    )
  }

  private companion object {
    const val CHANNEL_ID = "dayflow-capture"
    const val NOTIFICATION_ID = 301
    const val CAPTURE_INTERVAL_MS = 10_000L
    const val MAX_QUEUE_BYTES = 10_000_000_000L
  }
}
