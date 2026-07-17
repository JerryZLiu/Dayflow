package so.dayflow.capture

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import so.dayflow.capture.capture.CaptureState
import so.dayflow.capture.capture.PrivacyPreferences

class MainViewModel(application: Application) : AndroidViewModel(application) {
  private val app = application as DayflowCaptureApp
  private val privacy = PrivacyPreferences(application)
  private val _blockedApps = MutableStateFlow(privacy.blockedPackages().toSortedSet())

  val recordingState = CaptureState.state
  val recordingMessage = CaptureState.message
  val pairing = app.pairingStore.pairing
  val pendingCount = app.repository.pendingCount
  val pendingBytes = app.repository.pendingBytes
  val blockedApps = _blockedApps.asStateFlow()

  fun savePairing(raw: String): Result<Unit> = runCatching {
    app.pairingStore.save(raw)
    app.repository.scheduleSync()
  }

  fun clearPairing() = app.pairingStore.clear()
  fun syncNow() = app.repository.scheduleSync()

  fun addBlockedApp(value: String) {
    val normalized = value.trim()
    if (normalized.isEmpty()) return
    saveBlockedApps(_blockedApps.value + normalized)
  }

  fun removeBlockedApp(value: String) {
    saveBlockedApps(_blockedApps.value - value)
  }

  private fun saveBlockedApps(values: Set<String>) {
    val sorted = values.toSortedSet(String.CASE_INSENSITIVE_ORDER)
    privacy.save(sorted)
    _blockedApps.value = sorted
  }
}
