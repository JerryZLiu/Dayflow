package so.dayflow.capture.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairingStoreInstrumentationTest {
  @Test
  fun storesPairingPayloadFromInstrumentationArgument() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val payload = InstrumentationRegistry.getArguments().getString("pairingPayload")
    assertNotNull("Pass -e pairingPayload with a Dayflow pairing JSON payload", payload)

    val store = PairingStore(instrumentation.targetContext)
    val saved = store.save(requireNotNull(payload))

    assertEquals(1, saved.protocolVersion)
    assertEquals(saved.serviceId, store.pairing.value?.serviceId)
  }
}
