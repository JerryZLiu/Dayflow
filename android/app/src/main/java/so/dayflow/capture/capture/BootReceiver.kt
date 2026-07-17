package so.dayflow.capture.capture

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent?) {
    if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
    if (!CapturePreferences.isRecordingDesired(context) ||
      CapturePreferences.isManuallyPaused(context)
    ) return
    if (ContinuousCaptureAccessibilityService.isEnabled(context)) {
      ContextCompat.startForegroundService(
        context,
        Intent(context, CaptureService::class.java).setAction(CaptureActions.START)
      )
    } else {
      CaptureRecoveryNotifier.show(context)
    }
  }
}
