package so.dayflow.capture.capture

import android.app.KeyguardManager
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
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import so.dayflow.capture.DayflowCaptureApp
import so.dayflow.capture.MainActivity
import so.dayflow.capture.R

class CaptureService : LifecycleService() {
  private val processing = AtomicBoolean(false)
  private val mainHandler = Handler(Looper.getMainLooper())
  private val pauseState = CapturePauseState()
  private var sequence = 0L
  private var sessionId = UUID.randomUUID().toString()
  private var running = false
  private var stopping = false
  private lateinit var appReader: ForegroundAppReader
  private lateinit var privacy: PrivacyPreferences
  private val app by lazy { application as DayflowCaptureApp }

  private val captureLoop = object : Runnable {
    override fun run() {
      captureScreenIfPossible()
      mainHandler.postDelayed(this, CAPTURE_INTERVAL_MS)
    }
  }

  private val screenReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      when (intent?.action) {
        Intent.ACTION_SCREEN_OFF -> setPauseReason(CapturePauseReason.SCREEN_OFF, true)
        Intent.ACTION_SCREEN_ON -> resumeAfterUnlockIfPossible()
        Intent.ACTION_USER_PRESENT -> resumeAfterUnlockIfPossible()
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
        addAction(Intent.ACTION_SCREEN_ON)
        addAction(Intent.ACTION_USER_PRESENT)
      },
      RECEIVER_NOT_EXPORTED
    )
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    super.onStartCommand(intent, flags, startId)
    when (intent?.action) {
      CaptureActions.START -> startCapture()
      CaptureActions.PAUSE -> {
        CapturePreferences.setManuallyPaused(this, true)
        setPauseReason(CapturePauseReason.USER, true)
        if (!running) stopSelf()
      }
      CaptureActions.RESUME -> {
        CapturePreferences.setRecordingDesired(this, true)
        CapturePreferences.setManuallyPaused(this, false)
        if (running) setPauseReason(CapturePauseReason.USER, false) else startCapture()
      }
      CaptureActions.STOP -> stopCapture(userInitiated = true)
    }
    return Service.START_NOT_STICKY
  }

  private fun startCapture() {
    if (running) return
    startForegroundCapture()
    CapturePreferences.setRecordingDesired(this, true)
    if (!ContinuousCaptureAccessibilityService.isConnected()) {
      CaptureState.update(RecordingState.ERROR, getString(R.string.accessibility_service_not_ready))
      stopForeground(STOP_FOREGROUND_REMOVE)
      stopSelf()
      return
    }

    stopping = false
    running = true
    sessionId = UUID.randomUUID().toString()
    sequence = 0
    CaptureRecoveryNotifier.cancel(this)
    val power = getSystemService(PowerManager::class.java)
    setPauseReason(
      CapturePauseReason.USER,
      CapturePreferences.isManuallyPaused(this)
    )
    setPauseReason(CapturePauseReason.SCREEN_OFF, !power.isInteractive)
    publishCaptureState()
    updateNotification()
    mainHandler.removeCallbacks(captureLoop)
    mainHandler.post(captureLoop)
  }

  private fun captureScreenIfPossible() {
    if (!running || pauseState.isPaused) return
    val power = getSystemService(PowerManager::class.java)
    if (!power.isInteractive || !processing.compareAndSet(false, true)) return

    lifecycleScope.launch(Dispatchers.Default) {
      val foregroundApp = appReader.current()
      if (foregroundApp?.packageName == packageName) {
        processing.set(false)
        return@launch
      }
      if (foregroundApp != null && privacy.isBlocked(foregroundApp)) {
        sequence += 1
        try {
          app.repository.enqueueMetadata(
            sessionId = sessionId,
            sequence = sequence,
            foregroundAppId = foregroundApp.packageName,
            foregroundAppName = foregroundApp.label
          )
        } finally {
          processing.set(false)
        }
        return@launch
      }
      mainHandler.post { requestScreenshot(foregroundApp) }
    }
  }

  private fun requestScreenshot(foregroundApp: ForegroundApp?) {
    if (!running || pauseState.isPaused) {
      processing.set(false)
      return
    }

    val requested = ContinuousCaptureAccessibilityService.takeScreenshot(
      onSuccess = { bitmap ->
        lifecycleScope.launch(Dispatchers.Default) {
          try {
            processBitmap(bitmap, foregroundApp)
          } finally {
            bitmap.recycle()
            processing.set(false)
          }
        }
      },
      onFailure = {
        processing.set(false)
        CaptureState.update(RecordingState.RECORDING, getString(R.string.capture_unavailable))
      }
    )
    if (!requested) {
      processing.set(false)
      stopCapture(userInitiated = false)
    }
  }

  private suspend fun processBitmap(source: Bitmap, foregroundApp: ForegroundApp?) {
    val queuedBytes = app.database.captureDao().pendingByteCount()
    if (queuedBytes >= MAX_QUEUE_BYTES) {
      setPauseReason(CapturePauseReason.QUEUE_FULL, true)
      return
    }

    val scaled = scaleForUpload(source)
    val captureKind: String
    val output = if (scaled.isNearlyBlack()) {
      captureKind = "unavailable"
      if (scaled !== source) scaled.recycle()
      privatePlaceholder(source.width, source.height, getString(R.string.capture_unavailable))
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
    if (output !== source) output.recycle()
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
    var darkPixels = 0
    var sampledPixels = 0
    val stepX = (width / 16).coerceAtLeast(1)
    val stepY = (height / 24).coerceAtLeast(1)
    for (verticalPosition in 0 until height step stepY) {
      for (horizontalPosition in 0 until width step stepX) {
        val color = getPixel(horizontalPosition, verticalPosition)
        if (Color.red(color) + Color.green(color) + Color.blue(color) < 30) darkPixels++
        sampledPixels++
      }
    }
    return sampledPixels > 0 && darkPixels.toFloat() / sampledPixels > 0.97f
  }

  private fun setPauseReason(reason: CapturePauseReason, active: Boolean) {
    pauseState.set(reason, active)
    publishCaptureState()
    if (running) updateNotification()
  }

  private fun publishCaptureState() {
    if (!running) return
    val message = when (pauseState.primaryReason()) {
      CapturePauseReason.SCREEN_OFF -> getString(R.string.screen_locked_auto_resume)
      CapturePauseReason.QUEUE_FULL -> getString(R.string.queue_limit_reached)
      CapturePauseReason.USER -> getString(R.string.capture_paused_manually)
      null -> null
    }
    CaptureState.update(
      if (pauseState.isPaused) RecordingState.PAUSED else RecordingState.RECORDING,
      message
    )
  }

  private fun resumeAfterUnlockIfPossible() {
    val power = getSystemService(PowerManager::class.java)
    val keyguard = getSystemService(KeyguardManager::class.java)
    if (power.isInteractive && !keyguard.isDeviceLocked) {
      setPauseReason(CapturePauseReason.SCREEN_OFF, false)
    }
  }

  private fun stopCapture(userInitiated: Boolean) {
    if (stopping) return
    stopping = true
    running = false
    mainHandler.removeCallbacks(captureLoop)
    if (userInitiated) CapturePreferences.setRecordingDesired(this, false)
    CaptureState.update(
      if (userInitiated) RecordingState.STOPPED else RecordingState.ERROR,
      if (userInitiated) null else getString(R.string.accessibility_service_ended)
    )
    if (userInitiated) {
      CaptureRecoveryNotifier.cancel(this)
    } else {
      CaptureRecoveryNotifier.show(this)
    }
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf()
  }

  override fun onDestroy() {
    runCatching { unregisterReceiver(screenReceiver) }
    mainHandler.removeCallbacks(captureLoop)
    if (!stopping && CapturePreferences.isRecordingDesired(this)) {
      CaptureState.update(RecordingState.ERROR, getString(R.string.accessibility_service_ended))
      if (ContinuousCaptureAccessibilityService.isEnabled(this) &&
        !CapturePreferences.isManuallyPaused(this)
      ) {
        ContinuousCaptureAccessibilityService.ensureCaptureRunning(this, 1_000)
      } else if (!CapturePreferences.isManuallyPaused(this)) {
        CaptureRecoveryNotifier.show(this)
      }
    } else if (!CapturePreferences.isRecordingDesired(this)) {
      CaptureState.update(RecordingState.STOPPED)
    }
    super.onDestroy()
  }

  private fun startForegroundCapture() {
    ServiceCompat.startForeground(
      this,
      NOTIFICATION_ID,
      notification(),
      ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
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
    val manuallyPaused = pauseState.contains(CapturePauseReason.USER)
    val toggleAction = if (manuallyPaused) CaptureActions.RESUME else CaptureActions.PAUSE
    val toggleLabel = getString(if (manuallyPaused) R.string.resume_capture else R.string.pause_capture)
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
      .setContentTitle(getString(if (pauseState.isPaused) R.string.capture_notification_paused else R.string.capture_notification_active))
      .setContentText(getString(R.string.capture_notification_detail))
      .setOngoing(running)
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
