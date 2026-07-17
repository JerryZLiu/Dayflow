package so.dayflow.capture.capture

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import so.dayflow.capture.MainActivity
import so.dayflow.capture.R

object CaptureRecoveryNotifier {
  private const val CHANNEL_ID = "dayflow-restart"
  private const val NOTIFICATION_ID = 302

  fun show(context: Context) {
    val manager = context.getSystemService(NotificationManager::class.java)
    manager.createNotificationChannel(
      NotificationChannel(
        CHANNEL_ID,
        context.getString(R.string.restart_channel),
        NotificationManager.IMPORTANCE_DEFAULT
      )
    )
    val open = PendingIntent.getActivity(
      context,
      0,
      Intent(context, MainActivity::class.java),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
    manager.notify(
      NOTIFICATION_ID,
      NotificationCompat.Builder(context, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_dayflow)
        .setContentTitle(context.getString(R.string.restart_capture_title))
        .setContentText(context.getString(R.string.restart_capture_detail))
        .setContentIntent(open)
        .setAutoCancel(true)
        .build()
    )
  }

  fun cancel(context: Context) {
    context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
  }
}
