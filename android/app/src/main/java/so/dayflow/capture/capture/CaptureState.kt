package so.dayflow.capture.capture

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

enum class RecordingState { STOPPED, RECORDING, PAUSED, ERROR }

object CaptureState {
  private val _state = MutableStateFlow(RecordingState.STOPPED)
  val state: StateFlow<RecordingState> = _state
  private val _message = MutableStateFlow<String?>(null)
  val message: StateFlow<String?> = _message

  fun update(state: RecordingState, message: String? = null) {
    _state.value = state
    _message.value = message
  }
}

object CaptureActions {
  const val START = "so.dayflow.capture.START"
  const val PAUSE = "so.dayflow.capture.PAUSE"
  const val RESUME = "so.dayflow.capture.RESUME"
  const val STOP = "so.dayflow.capture.STOP"
}
