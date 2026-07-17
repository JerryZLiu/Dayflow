package so.dayflow.capture.sync

import android.content.Context
import android.os.Build
import android.util.Base64
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.AEADBadTagException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import so.dayflow.capture.DayflowCaptureApp
import so.dayflow.capture.data.CaptureDeviceWire
import so.dayflow.capture.data.DeviceIdentity
import so.dayflow.capture.data.SyncRequest
import so.dayflow.capture.data.toWire

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
  override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
    val app = applicationContext as DayflowCaptureApp
    val pairing = app.pairingStore.pairing.value ?: return@withContext Result.success()
    val pending = app.database.captureDao().pending()
    if (pending.isEmpty()) {
      app.repository.cleanup()
      return@withContext Result.success()
    }

    Log.i(TAG, "Starting sync for ${pending.size} pending captures")
    val endpoint = MacDiscovery(applicationContext).find(pairing)
      ?: run {
        Log.w(TAG, "Paired Mac could not be discovered")
        return@withContext Result.retry()
      }

    runCatching {
      EncryptedSyncClient(endpoint, pairing).use { client ->
        val deviceId = DeviceIdentity.id(applicationContext)
        client.send(
          SyncRequest(
            kind = "register",
            requestId = UUID.randomUUID().toString(),
            device = CaptureDeviceWire(
              id = deviceId,
              displayName = Build.MODEL,
              model = Build.PRODUCT,
              osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
            )
          )
        ).requireSuccess()

        val manifest = client.send(
          SyncRequest(
            kind = "manifest",
            requestId = UUID.randomUUID().toString(),
            deviceId = deviceId,
            captureIds = pending.map { it.captureId }
          )
        ).also { it.requireSuccess() }
        val missing = manifest.missingCaptureIds.orEmpty().toSet()
        val now = System.currentTimeMillis()
        pending.filterNot { missing.contains(it.captureId) }.forEach {
          app.database.captureDao().acknowledge(
            it.captureId,
            now,
            now + TimeUnit.HOURS.toMillis(24)
          )
        }

        val uploads = pending.filter { missing.contains(it.captureId) }
        if (uploads.isNotEmpty()) app.database.captureDao().markUploading(uploads.map { it.captureId })
        try {
          for (capture in uploads) {
            val file = File(capture.filePath)
            require(file.isFile) { "Missing capture ${capture.captureId}" }
            val response = client.send(
              SyncRequest(
                kind = "upload",
                requestId = UUID.randomUUID().toString(),
                metadata = capture.toWire(),
                imageBase64 = Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
              )
            )
            response.requireSuccess()
            val acknowledgedAt = System.currentTimeMillis()
            app.database.captureDao().acknowledge(
              capture.captureId,
              acknowledgedAt,
              acknowledgedAt + TimeUnit.HOURS.toMillis(24)
            )
          }
        } catch (error: Throwable) {
          app.database.captureDao().markPending(uploads.map { it.captureId })
          throw error
        }
      }
      app.repository.cleanup()
      Result.success()
    }.getOrElse { error ->
      Log.e(TAG, "Sync failed", error)
      if (error is AEADBadTagException) {
        app.pairingStore.clear()
        Result.failure()
      } else {
        Result.retry()
      }
    }
  }

  private fun so.dayflow.capture.data.SyncResponse.requireSuccess() {
    check(ok) { error ?: "Dayflow sync failed" }
  }

  private companion object {
    const val TAG = "DayflowSync"
  }
}
