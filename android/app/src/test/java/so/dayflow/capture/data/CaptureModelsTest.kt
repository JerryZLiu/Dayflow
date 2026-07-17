package so.dayflow.capture.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CaptureModelsTest {
  @Test
  fun metadataOnlyCaptureOmitsImageFieldsFromWirePayload() {
    val capture = CaptureEntity(
      captureId = "capture",
      deviceId = "device",
      sessionId = "session",
      sequence = 21,
      capturedAtUTCMS = 1_752_765_554_691,
      timezoneId = "Asia/Shanghai",
      utcOffsetSeconds = 28_800,
      foregroundAppId = "com.example.private",
      foregroundAppName = "Private App",
      orientation = "unknown",
      pixelWidth = 0,
      pixelHeight = 0,
      captureKind = "redacted",
      mimeType = "",
      byteLength = 0,
      sha256 = "",
      filePath = ""
    )

    val wire = capture.toWire()

    assertEquals("redacted", wire.kind)
    assertEquals("Private App", wire.foregroundAppName)
    assertNull(wire.pixelWidth)
    assertNull(wire.pixelHeight)
    assertNull(wire.mimeType)
    assertNull(wire.byteLength)
    assertNull(wire.sha256)
  }
}
