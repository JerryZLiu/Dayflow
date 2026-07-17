package so.dayflow.capture.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable

@Entity(
  tableName = "captures",
  indices = [Index(value = ["state", "capturedAtUTCMS"]), Index(value = ["deleteAfterUTCMS"])]
)
data class CaptureEntity(
  @PrimaryKey val captureId: String,
  val deviceId: String,
  val sessionId: String,
  val sequence: Long,
  val capturedAtUTCMS: Long,
  val timezoneId: String,
  val utcOffsetSeconds: Int,
  val foregroundAppId: String?,
  val foregroundAppName: String?,
  val orientation: String,
  val pixelWidth: Int,
  val pixelHeight: Int,
  val captureKind: String,
  val mimeType: String,
  val byteLength: Long,
  val sha256: String,
  val filePath: String,
  val state: String = SyncState.PENDING,
  val attemptCount: Int = 0,
  val acknowledgedAtUTCMS: Long? = null,
  val deleteAfterUTCMS: Long? = null
)

object SyncState {
  const val PENDING = "pending"
  const val UPLOADING = "uploading"
  const val ACKNOWLEDGED = "acknowledged"
}

@Serializable
data class PairingPayload(
  val protocolVersion: Int,
  val serviceType: String,
  val serviceName: String,
  val serviceId: String,
  val port: Int,
  val hostAddresses: List<String> = emptyList(),
  val sharedKey: String
)

@Serializable
data class CaptureDeviceWire(
  val id: String,
  val platform: String = "android",
  val displayName: String,
  val model: String?,
  val osVersion: String?,
  val pairedAt: Double? = null,
  val lastSeenAt: Double? = null,
  val isRevoked: Boolean = false
)

@Serializable
data class CaptureMetadataWire(
  val captureId: String,
  val deviceId: String,
  val sessionId: String?,
  val sequence: Long?,
  val capturedAtUTCMS: Long,
  val timezoneId: String,
  val utcOffsetSeconds: Int,
  val platform: String = "android",
  val foregroundAppId: String?,
  val foregroundAppName: String?,
  val orientation: String,
  val pixelWidth: Int?,
  val pixelHeight: Int?,
  val kind: String,
  val mimeType: String?,
  val byteLength: Long?,
  val sha256: String?
)

@Serializable
data class SyncRequest(
  val kind: String,
  val requestId: String,
  val device: CaptureDeviceWire? = null,
  val deviceId: String? = null,
  val captureIds: List<String>? = null,
  val metadata: CaptureMetadataWire? = null,
  val imageBase64: String? = null
)

@Serializable
data class SyncResponse(
  val requestId: String,
  val ok: Boolean,
  val missingCaptureIds: List<String>? = null,
  val acceptedCaptureId: String? = null,
  val error: String? = null,
  val serverTimeUTCMS: Long
)

fun CaptureEntity.toWire() = CaptureMetadataWire(
  captureId = captureId,
  deviceId = deviceId,
  sessionId = sessionId,
  sequence = sequence,
  capturedAtUTCMS = capturedAtUTCMS,
  timezoneId = timezoneId,
  utcOffsetSeconds = utcOffsetSeconds,
  foregroundAppId = foregroundAppId,
  foregroundAppName = foregroundAppName,
  orientation = orientation,
  pixelWidth = pixelWidth.takeIf { it > 0 },
  pixelHeight = pixelHeight.takeIf { it > 0 },
  kind = captureKind,
  mimeType = mimeType.takeIf { it.isNotBlank() },
  byteLength = byteLength.takeIf { it > 0 },
  sha256 = sha256.takeIf { it.isNotBlank() }
)
