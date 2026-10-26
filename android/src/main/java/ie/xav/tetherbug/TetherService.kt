package ie.xav.tetherbug

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.telephony.TelephonyManager
import android.util.Log
import java.util.concurrent.Executors
import rikka.shizuku.Shizuku

/**
 * Foreground service exposing the tetherbug BLE GATT service (see README "BLE protocol").
 * All characteristics require an encrypted link, so only a bonded Mac can read status or send
 * commands; the advertisement carries nothing but the service UUID.
 */
class TetherService : Service() {
    companion object {
        private const val TAG = "tetherbug"

        private const val PROTOCOL_VERSION: Byte = 3
        private const val FLAG_CONTROLLABLE = 1
        private const val CMD_ENABLE: Byte = 0x01

        // Hidden WifiManager AP-state broadcast and its states.
        private const val WIFI_AP_STATE_CHANGED = "android.net.wifi.WIFI_AP_STATE_CHANGED"
        private const val EXTRA_WIFI_AP_STATE = "wifi_state"
        private const val AP_ENABLING = 12
        private const val AP_ENABLED = 13
        private const val AP_FAILED = 14

        // Status hotspot byte.
        private const val HOTSPOT_OFF: Byte = 0
        private const val HOTSPOT_STARTING: Byte = 1
        private const val HOTSPOT_ON: Byte = 2
        private const val HOTSPOT_FAILED: Byte = 3
    }

    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var transport: BluetoothTransport
    private val handler = Handler(Looper.getMainLooper())
    private var hotspot = HOTSPOT_OFF
        set(value) {
            field = value
            TetherState.update { it.copy(hotspot = value) }
        }
    private var battery = 0
    // The running hotspot's frequency in MHz (0 unknown), from Shizuku once it's ready.
    @Volatile private var frequency = 0
    private var stopWatchingFrequency: (() -> Unit)? = null
    private var destroyed = false
    private val shizukuReceived = Shizuku.OnBinderReceivedListener { shizukuChanged() }
    private val shizukuDead = Shizuku.OnBinderDeadListener { shizukuChanged() }
    private val shizukuPermission = Shizuku.OnRequestPermissionResultListener { _, _ -> shizukuChanged() }

    /** Availability can change without an AP or battery event. Publish it over the existing link. */
    private fun shizukuChanged() {
        handler.post {
            if (destroyed) return@post
            watchFrequency()
            notifySubscribers()
        }
    }

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    WIFI_AP_STATE_CHANGED -> hotspot = hotspotState(intent.getIntExtra(EXTRA_WIFI_AP_STATE, 0))
                    Intent.ACTION_BATTERY_CHANGED -> {
                        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, 0)
                        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
                        val percent = level * 100 / scale
                        if (percent == battery) return
                        battery = percent
                    }
                }
                notifySubscribers()
            }
        }

    private fun hotspotState(apState: Int) =
        when (apState) {
            AP_ENABLING -> HOTSPOT_STARTING
            AP_ENABLED -> HOTSPOT_ON
            AP_FAILED -> HOTSPOT_FAILED
            else -> HOTSPOT_OFF
        }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        // The AP-state broadcast isn't sticky, so read the current state once.
        hotspot = hotspotState(Privileged.apState(getSystemService(WifiManager::class.java)))
        transport = BluetoothTransport(
            this, worker, ::status,
            credentials = { runCatching { Privileged.passphrase() }.getOrDefault("").toByteArray() },
            command = ::command,
            state = { advertising, count -> TetherState.update { it.copy(advertising = advertising, connectedMacs = count) } },
        )
        registerReceiver(receiver, IntentFilter(WIFI_AP_STATE_CHANGED).apply { addAction(Intent.ACTION_BATTERY_CHANGED) })
        TetherState.update { it.copy(running = true) }
        transport.start()
        Shizuku.addBinderDeadListener(shizukuDead)
        Shizuku.addRequestPermissionResultListener(shizukuPermission)
        Shizuku.addBinderReceivedListenerSticky(shizukuReceived)
        watchFrequency()
        pollHotspot()
    }

    /** The AP-state broadcast isn't reliably delivered, so also check the real state every few seconds. */
    private fun pollHotspot() {
        handler.postDelayed({
            watchFrequency()
            val actual = hotspotState(Privileged.apState(getSystemService(WifiManager::class.java)))
            if (actual != hotspot && hotspot != HOTSPOT_FAILED) {
                hotspot = actual
                notifySubscribers()
            }
            pollHotspot()
        }, 3000)
    }

    /** Starts following the hotspot's frequency once Shizuku is ready; a failure isn't retried. */
    private fun watchFrequency() {
        if (stopWatchingFrequency != null || !Privileged.isReady()) return
        stopWatchingFrequency =
            runCatching {
                Privileged.watchFrequency(this, mainExecutor) { mhz ->
                    if (mhz != frequency) {
                        frequency = mhz
                        notifySubscribers()
                    }
                }
            }.onFailure { Log.w(TAG, "can't watch the hotspot's frequency", it) }.getOrDefault {}
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onDestroy() {
        destroyed = true
        Shizuku.removeBinderDeadListener(shizukuDead)
        Shizuku.removeRequestPermissionResultListener(shizukuPermission)
        Shizuku.removeBinderReceivedListener(shizukuReceived)
        handler.removeCallbacksAndMessages(null)
        runCatching { stopWatchingFrequency?.invoke() }
        transport.close()
        TetherState.update { TetherState.Snapshot() }
        unregisterReceiver(receiver)
        worker.shutdown()
        super.onDestroy()
    }

    private fun status(): ByteArray {
        val signal = getSystemService(TelephonyManager::class.java).signalStrength?.level ?: 0
        val ssid = runCatching { Privileged.ssid() }.getOrNull().orEmpty()
        val flags = if (Privileged.isReady()) FLAG_CONTROLLABLE else 0
        val mhz = frequency
        return byteArrayOf(PROTOCOL_VERSION, hotspot, battery.toByte(), signal.toByte(), flags.toByte(), mhz.toByte(), (mhz shr 8).toByte()) +
            ssid.toByteArray()
    }

    private fun notifySubscribers() = transport.notifySubscribers()

    private fun command(cmd: Byte) {
        if (!Privileged.isReady()) {
            Log.w(TAG, "command $cmd ignored: Shizuku not ready")
            // Control being unavailable does not mean the hotspot itself failed.
            hotspot = hotspotState(Privileged.apState(getSystemService(WifiManager::class.java)))
            notifySubscribers()
            return
        }
        val enable = cmd == CMD_ENABLE
        if (hotspot == (if (enable) HOTSPOT_ON else HOTSPOT_OFF)) return notifySubscribers()
        Privileged.setHotspot(enable) { result ->
            if (result != 0) {
                Log.w(TAG, "tethering ${if (enable) "start" else "stop"} failed: $result")
                val actual = hotspotState(Privileged.apState(getSystemService(WifiManager::class.java)))
                // Rejected but already in the requested state (e.g. a duplicate enable) isn't a failure.
                hotspot = if (actual == (if (enable) HOTSPOT_ON else HOTSPOT_OFF)) actual else HOTSPOT_FAILED
                notifySubscribers()
            }
        }
    }

    private fun notification(): Notification {
        val channel = NotificationChannel("service", "Tetherbug", NotificationManager.IMPORTANCE_MIN)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        return Notification.Builder(this, channel.id)
            .setSmallIcon(R.drawable.ic_stat_tether)
            .setContentTitle("Tetherbug")
            .setContentText("Ready to share the hotspot with your Mac")
            .setOngoing(true)
            .build()
    }
}
