package so.dayflow.capture

import android.app.Application
import androidx.room.Room
import androidx.work.Configuration
import so.dayflow.capture.data.CaptureDatabase
import so.dayflow.capture.data.CaptureRepository
import so.dayflow.capture.sync.PairingStore

class DayflowCaptureApp : Application(), Configuration.Provider {
  lateinit var database: CaptureDatabase
    private set
  lateinit var repository: CaptureRepository
    private set
  lateinit var pairingStore: PairingStore
    private set

  override fun onCreate() {
    super.onCreate()
    database = Room.databaseBuilder(this, CaptureDatabase::class.java, "dayflow-captures.db")
      .fallbackToDestructiveMigration(false)
      .build()
    pairingStore = PairingStore(this)
    repository = CaptureRepository(this, database.captureDao())
  }

  override val workManagerConfiguration: Configuration
    get() = Configuration.Builder().setMinimumLoggingLevel(android.util.Log.INFO).build()
}

