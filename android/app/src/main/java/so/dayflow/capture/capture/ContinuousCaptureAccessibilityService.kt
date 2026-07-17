package so.dayflow.capture.capture

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.graphics.Bitmap
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import androidx.core.content.ContextCompat

class ContinuousCaptureAccessibilityService : AccessibilityService() {
  private val restartHandler = Handler(Looper.getMainLooper())
  private val screenReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      when (intent?.action) {
        Intent.ACTION_SCREEN_ON,
        Intent.ACTION_USER_PRESENT -> ensureCaptureRunning()
      }
    }
  }

  override fun onServiceConnected() {
    super.onServiceConnected()
    activeService = this
    registerReceiver(
      screenReceiver,
      IntentFilter().apply {
        addAction(Intent.ACTION_SCREEN_ON)
        addAction(Intent.ACTION_USER_PRESENT)
      },
      RECEIVER_NOT_EXPORTED
    )
    ensureCaptureRunning()
  }

  override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    if (event?.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
      ensureCaptureRunning()
    }
  }

  override fun onInterrupt() = Unit

  override fun onDestroy() {
    runCatching { unregisterReceiver(screenReceiver) }
    if (activeService === this) activeService = null
    super.onDestroy()
  }

  private fun ensureCaptureRunning() {
    if (!CapturePreferences.isRecordingDesired(this) ||
      CapturePreferences.isManuallyPaused(this)
    ) return
    ContextCompat.startForegroundService(
      this,
      Intent(this, CaptureService::class.java).setAction(CaptureActions.START)
    )
  }

  companion object {
    @Volatile
    private var activeService: ContinuousCaptureAccessibilityService? = null

    fun isEnabled(context: Context): Boolean {
      val expected = ComponentName(context, ContinuousCaptureAccessibilityService::class.java)
      val enabledServices = Settings.Secure.getString(
        context.contentResolver,
        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
      ).orEmpty()
      return enabledServices.split(':').any { flattenedName ->
        ComponentName.unflattenFromString(flattenedName) == expected
      }
    }

    fun isConnected(): Boolean = activeService != null

    fun ensureCaptureRunning(context: Context, delayMillis: Long = 0) {
      val service = activeService ?: return
      if (!CapturePreferences.isRecordingDesired(context) ||
        CapturePreferences.isManuallyPaused(context)
      ) return
      service.restartHandler.postDelayed({ service.ensureCaptureRunning() }, delayMillis)
    }

    fun takeScreenshot(
      onSuccess: (Bitmap) -> Unit,
      onFailure: (Int) -> Unit
    ): Boolean {
      val service = activeService ?: return false
      service.takeScreenshot(
        Display.DEFAULT_DISPLAY,
        service.mainExecutor,
        object : TakeScreenshotCallback {
          override fun onSuccess(screenshot: ScreenshotResult) {
            val bitmap = runCatching {
              val hardwareBuffer = screenshot.hardwareBuffer
              try {
                val wrapped = Bitmap.wrapHardwareBuffer(hardwareBuffer, screenshot.colorSpace)
                  ?: error("Unable to read accessibility screenshot")
                try {
                  wrapped.copy(Bitmap.Config.ARGB_8888, false)
                } finally {
                  wrapped.recycle()
                }
              } finally {
                hardwareBuffer.close()
              }
            }.getOrElse {
              onFailure(ERROR_TAKE_SCREENSHOT_INTERNAL_ERROR)
              return
            }
            onSuccess(bitmap)
          }

          override fun onFailure(errorCode: Int) {
            onFailure(errorCode)
          }
        }
      )
      return true
    }
  }
}
