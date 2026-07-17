package so.dayflow.capture.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface CaptureDao {
  @Insert(onConflict = OnConflictStrategy.IGNORE)
  suspend fun insert(capture: CaptureEntity): Long

  @Query("SELECT * FROM captures WHERE state != 'acknowledged' ORDER BY capturedAtUTCMS ASC LIMIT :limit")
  suspend fun pending(limit: Int = 500): List<CaptureEntity>

  @Query("SELECT COUNT(*) FROM captures WHERE state != 'acknowledged'")
  fun pendingCount(): Flow<Int>

  @Query("SELECT COALESCE(SUM(byteLength), 0) FROM captures WHERE state != 'acknowledged'")
  fun pendingBytes(): Flow<Long>

  @Query("SELECT COUNT(*) FROM captures WHERE state != 'acknowledged' AND filePath != ''")
  fun pendingImageCount(): Flow<Int>

  @Query("SELECT * FROM captures WHERE filePath != '' ORDER BY capturedAtUTCMS DESC LIMIT :limit")
  fun recentImages(limit: Int = 6): Flow<List<CaptureEntity>>

  @Query("SELECT COALESCE(SUM(byteLength), 0) FROM captures WHERE state != 'acknowledged'")
  suspend fun pendingByteCount(): Long

  @Query("UPDATE captures SET state = 'uploading', attemptCount = attemptCount + 1 WHERE captureId IN (:ids)")
  suspend fun markUploading(ids: List<String>)

  @Query("UPDATE captures SET state = 'pending' WHERE captureId IN (:ids) AND state = 'uploading'")
  suspend fun markPending(ids: List<String>)

  @Query("UPDATE captures SET state = 'acknowledged', acknowledgedAtUTCMS = :now, deleteAfterUTCMS = :deleteAfter WHERE captureId = :id")
  suspend fun acknowledge(id: String, now: Long, deleteAfter: Long)

  @Query("SELECT * FROM captures WHERE deleteAfterUTCMS IS NOT NULL AND deleteAfterUTCMS <= :now")
  suspend fun expiredAcknowledged(now: Long): List<CaptureEntity>

  @Query("SELECT * FROM captures WHERE state != 'acknowledged' AND capturedAtUTCMS < :cutoff")
  suspend fun expiredPending(cutoff: Long): List<CaptureEntity>

  @Query("DELETE FROM captures WHERE captureId IN (:ids)")
  suspend fun delete(ids: List<String>)
}
