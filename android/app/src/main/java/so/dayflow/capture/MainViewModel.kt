package so.dayflow.capture

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import so.dayflow.capture.capture.CaptureState
import so.dayflow.capture.capture.PrivacyPreferences

data class InstalledAppOption(val packageName: String, val label: String)

class MainViewModel(application: Application) : AndroidViewModel(application) {
  private val app = application as DayflowCaptureApp
  private val privacy = PrivacyPreferences(application)
  private val _blockedApps = MutableStateFlow(privacy.blockedPackages().toSortedSet())
  private val _installedApps = MutableStateFlow<List<InstalledAppOption>>(emptyList())

  val recordingState = CaptureState.state
  val recordingMessage = CaptureState.message
  val pairing = app.pairingStore.pairing
  val pendingCount = app.repository.pendingCount
  val pendingBytes = app.repository.pendingBytes
  val blockedApps = _blockedApps.asStateFlow()
  val installedApps = _installedApps.asStateFlow()

  init {
    refreshInstalledApps()
  }

  fun savePairing(raw: String): Result<Unit> = runCatching {
    app.pairingStore.save(raw)
    app.repository.scheduleSync(force = true)
  }

  fun clearPairing() = app.pairingStore.clear()
  fun syncNow() = app.repository.scheduleSync(force = true)

  fun addBlockedApp(value: String) {
    val normalized = value.trim()
    if (normalized.isEmpty()) return
    saveBlockedApps(_blockedApps.value + normalized)
  }

  fun removeBlockedApp(value: String) {
    saveBlockedApps(_blockedApps.value - value)
  }

  fun setAppExcluded(packageName: String, excluded: Boolean) {
    saveBlockedApps(
      if (excluded) _blockedApps.value + packageName else _blockedApps.value - packageName
    )
  }

  fun refreshInstalledApps() {
    viewModelScope.launch {
      _installedApps.value = withContext(Dispatchers.IO) {
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        app.packageManager.queryIntentActivities(launcherIntent, 0)
          .map { resolveInfo ->
            InstalledAppOption(
              packageName = resolveInfo.activityInfo.packageName,
              label = resolveInfo.loadLabel(app.packageManager).toString()
            )
          }
          .filterNot { it.packageName == app.packageName }
          .distinctBy { it.packageName }
          .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.label })
      }
    }
  }

  private fun saveBlockedApps(values: Set<String>) {
    val sorted = values.toSortedSet(String.CASE_INSENSITIVE_ORDER)
    privacy.save(sorted)
    _blockedApps.value = sorted
  }
}
