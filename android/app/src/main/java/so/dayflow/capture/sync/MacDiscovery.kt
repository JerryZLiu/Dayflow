package so.dayflow.capture.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import so.dayflow.capture.data.PairingPayload

data class MacEndpoint(val host: InetAddress, val port: Int)

class MacDiscovery(private val context: Context) {
  private val nsd = context.getSystemService(NsdManager::class.java)
  private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)

  suspend fun find(pairing: PairingPayload): MacEndpoint? {
    directEndpoint(pairing)?.let { return it }
    return discover(pairing)
  }

  private suspend fun directEndpoint(pairing: PairingPayload): MacEndpoint? =
    withContext(Dispatchers.IO) {
      if (pairing.port !in 1..65_535) return@withContext null
      pairing.hostAddresses.firstNotNullOfOrNull { rawHost ->
        runCatching {
          val address = InetAddress.getByName(rawHost)
          Socket().use { it.connect(InetSocketAddress(address, pairing.port), 1_000) }
          MacEndpoint(address, pairing.port)
        }.getOrNull()
      }
    }

  @Suppress("DEPRECATION")
  private suspend fun discover(pairing: PairingPayload): MacEndpoint? = withTimeoutOrNull(8_000) {
    suspendCancellableCoroutine { continuation ->
      val multicastLock = wifi.createMulticastLock("dayflow-mdns").apply {
        setReferenceCounted(false)
        acquire()
      }
      var finished = false
      lateinit var discoveryListener: NsdManager.DiscoveryListener

      fun finish(endpoint: MacEndpoint?) {
        if (finished) return
        finished = true
        runCatching { nsd.stopServiceDiscovery(discoveryListener) }
        if (multicastLock.isHeld) multicastLock.release()
        if (continuation.isActive) continuation.resume(endpoint)
      }

      discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = finish(null)
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

        override fun onServiceFound(service: NsdServiceInfo) {
          if (!service.serviceName.startsWith(pairing.serviceName)) return
          nsd.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
              val host = serviceInfo.host ?: return
              finish(MacEndpoint(host, serviceInfo.port))
            }
          })
        }

        override fun onServiceLost(service: NsdServiceInfo) = Unit
      }

      continuation.invokeOnCancellation {
        Handler(Looper.getMainLooper()).post { finish(null) }
      }
      nsd.discoverServices(pairing.serviceType + ".", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }
  }
}
