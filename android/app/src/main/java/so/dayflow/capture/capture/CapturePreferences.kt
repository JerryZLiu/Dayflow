package so.dayflow.capture.capture

import android.content.Context

object CapturePreferences {
  private const val PREFERENCES = "dayflow-capture-state"
  private const val RECORDING_DESIRED = "recording-desired"
  private const val MANUALLY_PAUSED = "manually-paused"

  fun isRecordingDesired(context: Context): Boolean =
    context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .getBoolean(RECORDING_DESIRED, false)

  fun setRecordingDesired(context: Context, desired: Boolean) {
    val editor = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .edit()
      .putBoolean(RECORDING_DESIRED, desired)
    if (!desired) editor.putBoolean(MANUALLY_PAUSED, false)
    editor.apply()
  }

  fun isManuallyPaused(context: Context): Boolean =
    context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .getBoolean(MANUALLY_PAUSED, false)

  fun setManuallyPaused(context: Context, paused: Boolean) {
    context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .edit()
      .putBoolean(MANUALLY_PAUSED, paused)
      .apply()
  }
}
