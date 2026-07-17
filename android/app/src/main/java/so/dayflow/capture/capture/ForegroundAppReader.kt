package so.dayflow.capture.capture

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context

data class ForegroundApp(val packageName: String, val label: String)

class ForegroundAppReader(private val context: Context) {
  private val usage = context.getSystemService(UsageStatsManager::class.java)

  fun current(): ForegroundApp? {
    val now = System.currentTimeMillis()
    val events = usage.queryEvents(now - 60_000, now)
    val event = UsageEvents.Event()
    var packageName: String? = null
    while (events.hasNextEvent()) {
      events.getNextEvent(event)
      if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED ||
        event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND
      ) {
        packageName = event.packageName
      }
    }
    val name = packageName ?: return null
    val label = runCatching {
      val info = context.packageManager.getApplicationInfo(name, 0)
      context.packageManager.getApplicationLabel(info).toString()
    }.getOrDefault(name)
    return ForegroundApp(name, label)
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

