package so.dayflow.capture.capture

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context

data class ForegroundApp(val packageName: String, val label: String)

class ForegroundAppReader(private val context: Context) {
  private val usage = context.getSystemService(UsageStatsManager::class.java)
  private var lastQueryAtUTCMS = 0L
  private var lastForegroundApp: ForegroundApp? = null

  fun current(): ForegroundApp? {
    val now = System.currentTimeMillis()
    val queryStart = if (lastQueryAtUTCMS == 0L) now - INITIAL_LOOKBACK_MS else lastQueryAtUTCMS - 1_000
    val events = usage.queryEvents(queryStart, now)
    val event = UsageEvents.Event()
    var packageName = lastForegroundApp?.packageName
    while (events.hasNextEvent()) {
      events.getNextEvent(event)
      if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED) {
        packageName = event.packageName
      }
    }
    lastQueryAtUTCMS = now
    val name = packageName ?: return lastForegroundApp
    if (name == lastForegroundApp?.packageName) return lastForegroundApp
    val label = runCatching {
      val info = context.packageManager.getApplicationInfo(name, 0)
      context.packageManager.getApplicationLabel(info).toString()
    }.getOrDefault(name)
    return ForegroundApp(name, label).also { lastForegroundApp = it }
  }

  private companion object {
    const val INITIAL_LOOKBACK_MS = 24 * 60 * 60 * 1_000L
  }
}

class PrivacyPreferences(context: Context) {
  private val preferences = context.getSharedPreferences("capture-privacy", Context.MODE_PRIVATE)

  fun isBlocked(app: ForegroundApp?): Boolean {
    val value = app ?: return false
    val blocked = preferences.getStringSet("blocked-packages", DEFAULT_BLOCKED).orEmpty()
    return blocked.any { hint ->
      value.packageName.contains(hint, ignoreCase = true) ||
        value.label.contains(hint, ignoreCase = true)
    }
  }

  fun blockedPackages(): Set<String> =
    preferences.getStringSet("blocked-packages", DEFAULT_BLOCKED).orEmpty()

  fun save(packages: Set<String>) {
    preferences.edit().putStringSet("blocked-packages", packages).apply()
  }

  private companion object {
    val DEFAULT_BLOCKED = setOf(
      "1password", "bitwarden", "keepass", "lastpass", "authenticator",
      "password", "bank", "wallet", "keychain", "protonpass"
    )
  }
}
