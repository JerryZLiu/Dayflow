package so.dayflow.capture

import android.Manifest
import android.app.AppOpsManager
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BatterySaver
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import so.dayflow.capture.capture.CaptureActions
import so.dayflow.capture.capture.CapturePreferences
import so.dayflow.capture.capture.CaptureService
import so.dayflow.capture.capture.CaptureState
import so.dayflow.capture.capture.ContinuousCaptureAccessibilityService
import so.dayflow.capture.capture.RecordingState
import so.dayflow.capture.data.CaptureEntity

class MainActivity : ComponentActivity() {
  private var usageAccessGranted by mutableStateOf(false)
  private var batteryUnrestricted by mutableStateOf(false)
  private var notificationsGranted by mutableStateOf(false)
  private var accessibilityGranted by mutableStateOf(false)

  private val permissionLauncher = registerForActivityResult(
    ActivityResultContracts.RequestMultiplePermissions()
  ) { refreshPermissionState() }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    refreshPermissionState()
    permissionLauncher.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS, Manifest.permission.CAMERA))
    setContent {
      DayflowTheme {
        val model: MainViewModel = viewModel()
        DayflowCaptureScreen(
          model = model,
          usageAccessGranted = usageAccessGranted,
          batteryUnrestricted = batteryUnrestricted,
          notificationsGranted = notificationsGranted,
          accessibilityGranted = accessibilityGranted,
          onStart = { requestCapture() },
          onAction = { action ->
            val serviceIntent = Intent(this, CaptureService::class.java).setAction(action)
            if (action == CaptureActions.RESUME) {
              ContextCompat.startForegroundService(this, serviceIntent)
            } else {
              startService(serviceIntent)
            }
          },
          onAccessibilitySettings = {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
          },
          onUsageSettings = {
            startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
          },
          onBatterySettings = {
            startActivity(
              Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:$packageName"))
            )
          },
          onNotificationPermission = {
            permissionLauncher.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
          }
        )
      }
    }
    if (CapturePreferences.isRecordingDesired(this) &&
      !CapturePreferences.isManuallyPaused(this) &&
      ContinuousCaptureAccessibilityService.isEnabled(this) &&
      CaptureState.state.value != RecordingState.RECORDING &&
      CaptureState.state.value != RecordingState.PAUSED
    ) {
      window.decorView.post { ContinuousCaptureAccessibilityService.ensureCaptureRunning(this) }
    }
  }

  override fun onResume() {
    super.onResume()
    refreshPermissionState()
    if (CapturePreferences.isRecordingDesired(this) &&
      !CapturePreferences.isManuallyPaused(this) &&
      accessibilityGranted
    ) {
      ContinuousCaptureAccessibilityService.ensureCaptureRunning(this)
    }
  }

  private fun refreshPermissionState() {
    usageAccessGranted = hasUsageAccess()
    batteryUnrestricted = isBatteryUnrestricted()
    notificationsGranted = ContextCompat.checkSelfPermission(
      this,
      Manifest.permission.POST_NOTIFICATIONS
    ) == PackageManager.PERMISSION_GRANTED
    accessibilityGranted = ContinuousCaptureAccessibilityService.isEnabled(this)
  }

  private fun requestCapture() {
    CapturePreferences.setRecordingDesired(this, true)
    CapturePreferences.setManuallyPaused(this, false)
    if (!ContinuousCaptureAccessibilityService.isEnabled(this)) {
      CaptureState.update(RecordingState.ERROR, getString(R.string.enable_accessibility_service))
      startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
      return
    }
    ContextCompat.startForegroundService(
      this,
      Intent(this, CaptureService::class.java).setAction(CaptureActions.START)
    )
  }

  private fun hasUsageAccess(): Boolean {
    val manager = getSystemService(AppOpsManager::class.java)
    return manager.unsafeCheckOpNoThrow(
      AppOpsManager.OPSTR_GET_USAGE_STATS,
      android.os.Process.myUid(),
      packageName
    ) == AppOpsManager.MODE_ALLOWED
  }

  private fun isBatteryUnrestricted(): Boolean =
    getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
}

@Composable
private fun DayflowCaptureScreen(
  model: MainViewModel,
  usageAccessGranted: Boolean,
  batteryUnrestricted: Boolean,
  notificationsGranted: Boolean,
  accessibilityGranted: Boolean,
  onStart: () -> Unit,
  onAction: (String) -> Unit,
  onAccessibilitySettings: () -> Unit,
  onUsageSettings: () -> Unit,
  onBatterySettings: () -> Unit,
  onNotificationPermission: () -> Unit
) {
  val recording by model.recordingState.collectAsState()
  val message by model.recordingMessage.collectAsState()
  val pairing by model.pairing.collectAsState()
  val pendingCount by model.pendingCount.collectAsState(initial = 0)
  val pendingBytes by model.pendingBytes.collectAsState(initial = 0)
  val pendingImageCount by model.pendingImageCount.collectAsState(initial = 0)
  val recentImages by model.recentImages.collectAsState(initial = emptyList())
  val blockedApps by model.blockedApps.collectAsState()
  val installedApps by model.installedApps.collectAsState()
  val context = LocalContext.current
  val clipboardManager = remember(context) {
    context.getSystemService(ClipboardManager::class.java)
  }
  var scansQr by remember { mutableStateOf(false) }
  var pairingError by remember { mutableStateOf<String?>(null) }
  var selectsExcludedApps by remember { mutableStateOf(false) }
  var previewCapture by remember { mutableStateOf<CaptureEntity?>(null) }

  if (scansQr) {
    QrScannerView(
      onResult = { raw ->
        model.savePairing(raw)
          .onSuccess { scansQr = false; pairingError = null }
          .onFailure { pairingError = it.message }
      },
      onClose = { scansQr = false }
    )
    return
  }

  Surface(Modifier.fillMaxSize(), color = Color(0xFFF7F7F5)) {
    Column(
      modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
      verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
      Text(stringResource(R.string.main_title), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
      StatusCard(recording, message, pendingCount, pendingBytes)

      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        when (recording) {
          RecordingState.STOPPED, RecordingState.ERROR -> PrimaryAction(stringResource(R.string.start_capture), Icons.Rounded.PlayArrow, onStart)
          RecordingState.RECORDING -> PrimaryAction(stringResource(R.string.pause_capture), Icons.Rounded.Pause) {
            onAction(CaptureActions.PAUSE)
          }
          RecordingState.PAUSED -> PrimaryAction(stringResource(R.string.resume_capture), Icons.Rounded.PlayArrow) {
            onAction(CaptureActions.RESUME)
          }
        }
        OutlinedButton(onClick = { onAction(CaptureActions.STOP) }, enabled = recording != RecordingState.STOPPED) {
          Icon(Icons.Rounded.Stop, null)
          Text(stringResource(R.string.stop_capture), Modifier.padding(start = 6.dp))
        }
      }

      SectionCard(stringResource(R.string.upload_storage)) {
        SettingRow(
          icon = Icons.Rounded.Folder,
          title = stringResource(R.string.pending_images, pendingImageCount),
          detail = model.captureStoragePath
        )
        Text(
          stringResource(R.string.upload_storage_detail),
          style = MaterialTheme.typography.bodySmall,
          color = Color(0xFF777773)
        )
        if (recentImages.isNotEmpty()) {
          Text(stringResource(R.string.recent_image_previews), fontWeight = FontWeight.Medium)
          LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(recentImages, key = { it.captureId }) { capture ->
              val preview = remember(capture.captureId, capture.filePath) {
                decodePreview(capture.filePath, 320)
              }
              Column(
                modifier = Modifier.clickable(enabled = preview != null) {
                  previewCapture = capture
                },
                horizontalAlignment = Alignment.CenterHorizontally
              ) {
                if (preview != null) {
                  Image(
                    bitmap = preview,
                    contentDescription = capture.foregroundAppName,
                    modifier = Modifier.size(width = 104.dp, height = 164.dp)
                      .clip(RoundedCornerShape(8.dp)),
                    contentScale = ContentScale.Crop
                  )
                }
                Text(
                  capture.foregroundAppName ?: stringResource(R.string.unknown_app),
                  style = MaterialTheme.typography.bodySmall,
                  modifier = Modifier.padding(top = 4.dp)
                )
              }
            }
          }
        }
        OutlinedButton(onClick = {
          clipboardManager.setPrimaryClip(
            ClipData.newPlainText(context.getString(R.string.upload_storage), model.captureStoragePath)
          )
        }) {
          Icon(Icons.Rounded.ContentCopy, null)
          Text(stringResource(R.string.copy_path), Modifier.padding(start = 6.dp))
        }
      }

      SectionCard(stringResource(R.string.mac_connection)) {
        SettingRow(
          icon = Icons.Rounded.Computer,
          title = pairing?.serviceName ?: stringResource(R.string.no_mac_paired),
          detail = if (pairing == null) stringResource(R.string.scan_mac_code) else stringResource(R.string.encrypted_sync_enabled)
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
          Button(onClick = { scansQr = true }) {
            Icon(Icons.Rounded.QrCodeScanner, null)
            Text(if (pairing == null) stringResource(R.string.pair_mac) else stringResource(R.string.pair_again), Modifier.padding(start = 6.dp))
          }
          OutlinedButton(onClick = model::syncNow, enabled = pairing != null) {
            Icon(Icons.Rounded.Refresh, null)
            Text(stringResource(R.string.sync_now), Modifier.padding(start = 6.dp))
          }
          if (pairing != null) {
            IconButton(onClick = model::clearPairing) {
              Icon(Icons.Rounded.DeleteOutline, stringResource(R.string.remove_pairing))
            }
          }
        }
        pairingError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
      }

      SectionCard(stringResource(R.string.device_access)) {
        PermissionRow(
          stringResource(R.string.continuous_capture_access),
          accessibilityGranted,
          Icons.Rounded.Security,
          onAccessibilitySettings
        )
        PermissionRow(stringResource(R.string.usage_access), usageAccessGranted, Icons.Rounded.Security, onUsageSettings)
        PermissionRow(stringResource(R.string.unrestricted_battery), batteryUnrestricted, Icons.Rounded.BatterySaver, onBatterySettings)
        PermissionRow(
          stringResource(R.string.notifications),
          notificationsGranted,
          Icons.Rounded.Notifications,
          onNotificationPermission
        )
      }

      SectionCard(stringResource(R.string.privacy)) {
        SettingRow(
          icon = Icons.Rounded.Security,
          title = stringResource(R.string.excluded_apps),
          detail = stringResource(R.string.excluded_apps_detail)
        )
        Text(
          stringResource(R.string.automatic_sensitive_protection),
          style = MaterialTheme.typography.bodySmall,
          color = Color(0xFF777773)
        )
        installedApps.filter { blockedApps.contains(it.packageName) }.forEach { app ->
          Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
          ) {
            Column(Modifier.weight(1f)) {
              Text(app.label, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
              Text(app.packageName, style = MaterialTheme.typography.bodySmall, color = Color(0xFF777773))
            }
            IconButton(onClick = { model.setAppExcluded(app.packageName, false) }) {
              Icon(Icons.Rounded.DeleteOutline, stringResource(R.string.remove_excluded_app, app.label))
            }
          }
        }
        OutlinedButton(onClick = {
          model.refreshInstalledApps()
          selectsExcludedApps = true
        }) {
          Icon(Icons.Rounded.Add, null)
          Text(stringResource(R.string.select_apps), Modifier.padding(start = 6.dp))
        }
      }
    }
  }

  if (selectsExcludedApps) {
    AlertDialog(
      onDismissRequest = { selectsExcludedApps = false },
      title = { Text(stringResource(R.string.select_apps_title)) },
      text = {
        if (installedApps.isEmpty()) {
          Text(stringResource(R.string.no_apps_found))
        } else {
          LazyColumn(Modifier.fillMaxWidth().heightIn(max = 440.dp)) {
            items(installedApps, key = { it.packageName }) { app ->
              val excluded = blockedApps.contains(app.packageName)
              Row(
                modifier = Modifier
                  .fillMaxWidth()
                  .clickable { model.setAppExcluded(app.packageName, !excluded) }
                  .padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
              ) {
                Checkbox(checked = excluded, onCheckedChange = null)
                Column(Modifier.padding(start = 8.dp)) {
                  Text(app.label, fontWeight = FontWeight.Medium)
                  Text(
                    app.packageName,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color(0xFF777773)
                  )
                }
              }
            }
          }
        }
      },
      confirmButton = {
        TextButton(onClick = { selectsExcludedApps = false }) {
          Text(stringResource(R.string.done))
        }
      }
    )
  }

  previewCapture?.let { capture ->
    val preview = remember(capture.captureId, capture.filePath) {
      decodePreview(capture.filePath, 1200)
    }
    AlertDialog(
      onDismissRequest = { previewCapture = null },
      title = { Text(capture.foregroundAppName ?: stringResource(R.string.image_preview)) },
      text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
          if (preview != null) {
            Image(
              bitmap = preview,
              contentDescription = capture.foregroundAppName,
              modifier = Modifier.fillMaxWidth().height(520.dp),
              contentScale = ContentScale.Fit
            )
          }
          Text(capture.filePath, style = MaterialTheme.typography.bodySmall)
        }
      },
      confirmButton = {
        TextButton(onClick = { previewCapture = null }) {
          Text(stringResource(R.string.close_preview))
        }
      }
    )
  }
}

private fun decodePreview(path: String, maxDimension: Int) = runCatching {
  val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
  BitmapFactory.decodeFile(path, bounds)
  if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@runCatching null

  var sampleSize = 1
  while (maxOf(bounds.outWidth, bounds.outHeight) / sampleSize > maxDimension * 2) {
    sampleSize *= 2
  }
  BitmapFactory.decodeFile(
    path,
    BitmapFactory.Options().apply { inSampleSize = sampleSize }
  )?.asImageBitmap()
}.getOrNull()

@Composable
private fun StatusCard(state: RecordingState, message: String?, count: Int, bytes: Long) {
  val color = when (state) {
    RecordingState.RECORDING -> Color(0xFF2C8B57)
    RecordingState.PAUSED -> Color(0xFFD17922)
    RecordingState.ERROR -> Color(0xFFB84A42)
    RecordingState.STOPPED -> Color(0xFF777773)
  }
  Card(shape = RoundedCornerShape(8.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
    Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
      Box(Modifier.size(10.dp).background(color, RoundedCornerShape(5.dp)))
      Column(Modifier.padding(start = 10.dp).weight(1f)) {
        Text(
          stringResource(
            when (state) {
              RecordingState.STOPPED -> R.string.state_stopped
              RecordingState.RECORDING -> R.string.state_recording
              RecordingState.PAUSED -> R.string.state_paused
              RecordingState.ERROR -> R.string.state_error
            }
          ),
          fontWeight = FontWeight.SemiBold
        )
        message?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = color) }
      }
      Text(stringResource(R.string.queue_status, count, formatBytes(bytes)), style = MaterialTheme.typography.bodySmall)
    }
  }
}

@Composable
private fun SectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
  Card(shape = RoundedCornerShape(8.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
      Text(title, fontWeight = FontWeight.SemiBold)
      content()
    }
  }
}

@Composable
private fun SettingRow(icon: ImageVector, title: String, detail: String) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Icon(icon, null, tint = Color(0xFF555550))
    Column(Modifier.padding(start = 10.dp).weight(1f)) {
      Text(title, fontWeight = FontWeight.Medium)
      Text(detail, style = MaterialTheme.typography.bodySmall, color = Color(0xFF777773))
    }
  }
}

@Composable
private fun PermissionRow(
  title: String,
  granted: Boolean,
  icon: ImageVector,
  action: (() -> Unit)?
) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Icon(icon, null, tint = if (granted) Color(0xFF2C8B57) else Color(0xFFD17922))
    Text(title, Modifier.padding(start = 10.dp).weight(1f))
    if (granted) {
      Text(stringResource(R.string.ready), color = Color(0xFF2C8B57), style = MaterialTheme.typography.bodySmall)
    } else if (action != null) {
      OutlinedButton(onClick = action) { Text(stringResource(R.string.open_settings)) }
    }
  }
}

@Composable
private fun PrimaryAction(label: String, icon: ImageVector, action: () -> Unit) {
  Button(
    onClick = action,
    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFF96E00))
  ) {
    Icon(icon, null)
    Text(label, Modifier.padding(start = 6.dp))
  }
}

private fun formatBytes(bytes: Long): String = when {
  bytes >= 1_000_000_000 -> "%.1f GB".format(bytes / 1_000_000_000.0)
  bytes >= 1_000_000 -> "%.1f MB".format(bytes / 1_000_000.0)
  bytes >= 1_000 -> "%.1f KB".format(bytes / 1_000.0)
  else -> "$bytes B"
}

@Composable
private fun DayflowTheme(content: @Composable () -> Unit) {
  MaterialTheme(
    colorScheme = MaterialTheme.colorScheme.copy(
      primary = Color(0xFFF96E00),
      secondary = Color(0xFF2C8B57),
      surface = Color.White,
      background = Color(0xFFF7F7F5)
    ),
    content = content
  )
}
