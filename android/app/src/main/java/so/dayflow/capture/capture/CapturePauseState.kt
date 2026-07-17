package so.dayflow.capture.capture

enum class CapturePauseReason {
  USER,
  SCREEN_OFF,
  QUEUE_FULL
}

class CapturePauseState {
  private val reasons = mutableSetOf<CapturePauseReason>()

  val isPaused: Boolean
    get() = reasons.isNotEmpty()

  fun set(reason: CapturePauseReason, active: Boolean): Boolean {
    val changed = if (active) reasons.add(reason) else reasons.remove(reason)
    return changed
  }

  fun contains(reason: CapturePauseReason): Boolean = reasons.contains(reason)

  fun primaryReason(): CapturePauseReason? = when {
    reasons.contains(CapturePauseReason.QUEUE_FULL) -> CapturePauseReason.QUEUE_FULL
    reasons.contains(CapturePauseReason.USER) -> CapturePauseReason.USER
    reasons.contains(CapturePauseReason.SCREEN_OFF) -> CapturePauseReason.SCREEN_OFF
    else -> null
  }
}
