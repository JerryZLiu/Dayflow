package so.dayflow.capture.capture

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import so.dayflow.capture.MainActivity

class CaptureTileService : TileService() {
  override fun onStartListening() {
    super.onStartListening()
    qsTile?.state = when (CaptureState.state.value) {
      RecordingState.RECORDING -> Tile.STATE_ACTIVE
      RecordingState.PAUSED -> Tile.STATE_INACTIVE
      else -> Tile.STATE_UNAVAILABLE
    }
    qsTile?.updateTile()
  }

  override fun onClick() {
    super.onClick()
    when (CaptureState.state.value) {
      RecordingState.RECORDING -> startService(
        Intent(this, CaptureService::class.java).setAction(CaptureActions.PAUSE)
      )
      RecordingState.PAUSED -> startService(
        Intent(this, CaptureService::class.java).setAction(CaptureActions.RESUME)
      )
      else -> startActivityAndCollapse(
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      )
    }
  }
}

