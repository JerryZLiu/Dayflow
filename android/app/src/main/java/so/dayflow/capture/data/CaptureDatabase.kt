package so.dayflow.capture.data

import androidx.room.Database
import androidx.room.RoomDatabase

@Database(entities = [CaptureEntity::class], version = 1, exportSchema = false)
abstract class CaptureDatabase : RoomDatabase() {
  abstract fun captureDao(): CaptureDao
}
