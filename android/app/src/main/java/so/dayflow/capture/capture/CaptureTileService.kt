package so.dayflow.capture.capture

import android.app.PendingIntent
import android.content.Intent
import androidx.core.content.ContextCompat
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import so.dayflow.capture.MainActivity

class CaptureTileService : TileService() {
  override fun onStartListening() {
    super.onStartListening()
    qsTile?.state = when {
      !ContinuousCaptureAccessibilityService.isEnabled(this) -> Tile.STATE_UNAVAILABLE
      !CapturePreferences.isRecordingDesired(this) -> Tile.STATE_INACTIVE
      CapturePreferences.isManuallyPaused(this) -> Tile.STATE_INACTIVE
      else -> Tile.STATE_ACTIVE
    }
    qsTile?.updateTile()
  }

  override fun onClick() {
    super.onClick()
    if (!ContinuousCaptureAccessibilityService.isEnabled(this)) {
      startActivityAndCollapse(
        PendingIntent.getActivity(
          this,
          0,
          Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
          PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
      )
      return
    }

    val action = if (CapturePreferences.isRecordingDesired(this) &&
      !CapturePreferences.isManuallyPaused(this)
    ) CaptureActions.PAUSE else CaptureActions.RESUME
    val serviceIntent = Intent(this, CaptureService::class.java).setAction(action)
    if (action == CaptureActions.RESUME) {
      ContextCompat.startForegroundService(this, serviceIntent)
    } else {
      startService(serviceIntent)
    }
    qsTile?.state = if (action == CaptureActions.PAUSE) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
    qsTile?.updateTile()
  }
}
