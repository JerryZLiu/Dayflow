package so.dayflow.capture.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CapturePauseStateTest {
  @Test
  fun unlockOnlyClearsScreenPause() {
    val state = CapturePauseState()
    state.set(CapturePauseReason.USER, true)
    state.set(CapturePauseReason.SCREEN_OFF, true)

    state.set(CapturePauseReason.SCREEN_OFF, false)

    assertTrue(state.isPaused)
    assertTrue(state.contains(CapturePauseReason.USER))
    assertEquals(CapturePauseReason.USER, state.primaryReason())
  }

  @Test
  fun queueLimitCannotBeBypassedByUnlock() {
    val state = CapturePauseState()
    state.set(CapturePauseReason.QUEUE_FULL, true)
    state.set(CapturePauseReason.SCREEN_OFF, true)

    state.set(CapturePauseReason.SCREEN_OFF, false)

    assertTrue(state.isPaused)
    assertEquals(CapturePauseReason.QUEUE_FULL, state.primaryReason())
  }

  @Test
  fun screenOnlyPauseResumesAfterUnlock() {
    val state = CapturePauseState()
    state.set(CapturePauseReason.SCREEN_OFF, true)

    state.set(CapturePauseReason.SCREEN_OFF, false)

    assertFalse(state.isPaused)
    assertEquals(null, state.primaryReason())
  }
}
