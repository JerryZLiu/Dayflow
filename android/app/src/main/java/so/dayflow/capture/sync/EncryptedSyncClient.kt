package so.dayflow.capture.sync

import android.util.Base64
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import so.dayflow.capture.data.PairingPayload
import so.dayflow.capture.data.SyncRequest
import so.dayflow.capture.data.SyncResponse

class EncryptedSyncClient(
  endpoint: MacEndpoint,
  private val pairing: PairingPayload
) : Closeable {
  private val socket = Socket().apply {
    connect(InetSocketAddress(endpoint.host, endpoint.port), 10_000)
    soTimeout = 20_000
    tcpNoDelay = true
  }
  private val input = DataInputStream(socket.getInputStream().buffered())
  private val output = DataOutputStream(socket.getOutputStream().buffered())
  private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
  private val key = SecretKeySpec(Base64.decode(pairing.sharedKey, Base64.DEFAULT), "AES")

  fun send(request: SyncRequest): SyncResponse {
    val plaintext = json.encodeToString(request).toByteArray(Charsets.UTF_8)
    val encrypted = encrypt(plaintext)
    require(encrypted.size <= MAX_FRAME_BYTES)
    output.writeInt(encrypted.size)
    output.write(encrypted)
    output.flush()

    val responseLength = input.readInt()
    require(responseLength in 1..MAX_FRAME_BYTES) { "Invalid Dayflow response" }
    val responseBytes = ByteArray(responseLength)
    input.readFully(responseBytes)
    return json.decodeFromString<SyncResponse>(decrypt(responseBytes))
  }

  private fun encrypt(plaintext: ByteArray): ByteArray {
    val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
    cipher.updateAAD(pairing.serviceId.toByteArray(Charsets.UTF_8))
    return nonce + cipher.doFinal(plaintext)
  }

  private fun decrypt(combined: ByteArray): String {
    require(combined.size > 28)
    val nonce = combined.copyOfRange(0, 12)
    val ciphertext = combined.copyOfRange(12, combined.size)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce))
    cipher.updateAAD(pairing.serviceId.toByteArray(Charsets.UTF_8))
    return cipher.doFinal(ciphertext).toString(Charsets.UTF_8)
  }

  override fun close() {
    runCatching { socket.close() }
  }

  private companion object {
    const val MAX_FRAME_BYTES = 12 * 1024 * 1024
  }
}

