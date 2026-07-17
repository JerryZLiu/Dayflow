package so.dayflow.capture.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import so.dayflow.capture.data.PairingPayload

class PairingStore(private val context: Context) {
  private val preferences = context.getSharedPreferences("dayflow-pairing", Context.MODE_PRIVATE)
  private val json = Json { ignoreUnknownKeys = true }
  private val _pairing = MutableStateFlow(load())
  val pairing: StateFlow<PairingPayload?> = _pairing

  fun save(rawJson: String): PairingPayload {
    val payload = json.decodeFromString<PairingPayload>(rawJson)
    require(payload.protocolVersion == 1) { "不支持这个 Dayflow 配对协议" }
    require(Base64.decode(payload.sharedKey, Base64.DEFAULT).size == 32) { "配对密钥无效" }

    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, secretKey())
    val encrypted = cipher.doFinal(rawJson.toByteArray(Charsets.UTF_8))
    preferences.edit()
      .putString("nonce", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
      .putString("payload", Base64.encodeToString(encrypted, Base64.NO_WRAP))
      .apply()
    _pairing.value = payload
    return payload
  }

  fun clear() {
    preferences.edit().clear().apply()
    _pairing.value = null
  }

  private fun load(): PairingPayload? = runCatching {
    val nonce = Base64.decode(preferences.getString("nonce", null), Base64.NO_WRAP)
    val encrypted = Base64.decode(preferences.getString("payload", null), Base64.NO_WRAP)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, nonce))
    json.decodeFromString<PairingPayload>(
      cipher.doFinal(encrypted).toString(Charsets.UTF_8)
    )
  }.getOrNull()

  private fun secretKey(): SecretKey {
    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
    return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
      init(
        KeyGenParameterSpec.Builder(
          KEY_ALIAS,
          KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
          .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
          .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
          .build()
      )
      generateKey()
    }
  }

  private companion object {
    const val KEY_ALIAS = "dayflow-android-pairing"
  }
}
