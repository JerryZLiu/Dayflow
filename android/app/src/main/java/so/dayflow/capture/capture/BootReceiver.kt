package so.dayflow.capture.capture

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import so.dayflow.capture.MainActivity
import so.dayflow.capture.R

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent?) {
    if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
    val manager = context.getSystemService(NotificationManager::class.java)
    val channel = "dayflow-restart"
    manager.createNotificationChannel(
      NotificationChannel(channel, context.getString(R.string.restart_channel), NotificationManager.IMPORTANCE_DEFAULT)
    )
    val open = PendingIntent.getActivity(
      context,
      0,
      Intent(context, MainActivity::class.java),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
    manager.notify(
      302,
      NotificationCompat.Builder(context, channel)
        .setSmallIcon(R.drawable.ic_dayflow)
        .setContentTitle(context.getString(R.string.restart_capture_title))
        .setContentText(context.getString(R.string.restart_capture_detail))
        .setContentIntent(open)
        .setAutoCancel(true)
        .build()
    )
  }
}
