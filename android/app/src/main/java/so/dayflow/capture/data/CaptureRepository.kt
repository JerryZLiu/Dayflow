package so.dayflow.capture.data

import android.content.Context
import android.graphics.Bitmap
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import so.dayflow.capture.sync.SyncWorker

class CaptureRepository(
  private val context: Context,
  private val dao: CaptureDao
) {
  val pendingCount = dao.pendingCount()
  val pendingBytes = dao.pendingBytes()

  suspend fun enqueue(
    bitmap: Bitmap,
    sessionId: String,
    sequence: Long,
    foregroundAppId: String?,
    foregroundAppName: String?,
    captureKind: String,
    orientation: String
  ): CaptureEntity = withContext(Dispatchers.IO) {
    val captureId = UUID.randomUUID().toString()
    val now = System.currentTimeMillis()
    val directory = File(context.filesDir, "captures").apply { mkdirs() }
    val file = File(directory, "$captureId.jpg")
    file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it) }
    val bytes = file.readBytes()
    val zone = ZoneId.systemDefault()
    val offset = zone.rules.getOffset(Instant.ofEpochMilli(now)).totalSeconds
    val entity = CaptureEntity(
      captureId = captureId,
      deviceId = DeviceIdentity.id(context),
      sessionId = sessionId,
      sequence = sequence,
      capturedAtUTCMS = now,
      timezoneId = zone.id,
      utcOffsetSeconds = offset,
      foregroundAppId = foregroundAppId,
      foregroundAppName = foregroundAppName,
      orientation = orientation,
      pixelWidth = bitmap.width,
      pixelHeight = bitmap.height,
      captureKind = captureKind,
      mimeType = "image/jpeg",
      byteLength = bytes.size.toLong(),
      sha256 = bytes.sha256(),
      filePath = file.absolutePath
    )
    dao.insert(entity)
    scheduleSync()
    entity
  }

  fun scheduleSync(force: Boolean = false) {
    val builder = OneTimeWorkRequestBuilder<SyncWorker>()
    if (!force) builder.setInitialDelay(2, TimeUnit.SECONDS)
    val request = builder.build()
    WorkManager.getInstance(context).enqueueUniqueWork(
      "dayflow-sync",
      if (force) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
      request
    )
  }

  suspend fun cleanup() = withContext(Dispatchers.IO) {
    val now = System.currentTimeMillis()
    val acknowledged = dao.expiredAcknowledged(now)
    acknowledged.forEach { File(it.filePath).delete() }
    if (acknowledged.isNotEmpty()) dao.delete(acknowledged.map { it.captureId })

    val sevenDaysAgo = now - TimeUnit.DAYS.toMillis(7)
    val stale = dao.expiredPending(sevenDaysAgo)
    if (stale.isNotEmpty()) {
      // Unacknowledged data is never silently deleted. CaptureService checks the quota and pauses.
    }
  }

  private fun ByteArray.sha256(): String = MessageDigest.getInstance("SHA-256")
    .digest(this)
    .joinToString("") { "%02x".format(it) }
}

object DeviceIdentity {
  private const val PREFS = "dayflow-device"
  private const val KEY = "device-id"

  fun id(context: Context): String {
    val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    return preferences.getString(KEY, null) ?: UUID.randomUUID().toString().also {
      preferences.edit().putString(KEY, it).apply()
    }
  }
}
