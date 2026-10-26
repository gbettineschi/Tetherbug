package ie.xav.tetherbug

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.AttributionSource
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID
import java.util.concurrent.Executor

/** Owns the BLE boundary; each server keeps its own callbacks and queued work. */
@SuppressLint("MissingPermission") // The setup screen grants CONNECT/ADVERTISE before starting us.
internal class BluetoothTransport(
    private val context: Context,
    private val worker: Executor,
    private val status: () -> ByteArray,
    private val credentials: () -> ByteArray,
    private val command: (Byte) -> Unit,
    private val state: (Boolean, Int) -> Unit,
    private val linkEncrypted: (BluetoothDevice) -> Boolean = { device -> encryptedLE(context, device) },
) : AutoCloseable {
    companion object {
        val SERVICE: UUID = UUID.fromString("1581bac4-33fe-43a8-b97f-5dd7a01f48c9")
        val STATUS: UUID = UUID.fromString("90766fca-8a24-43ae-8501-3dcef06a8479")
        val COMMAND: UUID = UUID.fromString("e036426f-6317-487d-8777-e6f6d91f8a4d")
        val CREDENTIALS: UUID = UUID.fromString("355534b0-7222-480b-aa18-02a6c30feea2")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val TAG = "tetherbug"
        private const val RETRY_MS = 5000L

        private fun encryptedLE(context: Context, device: BluetoothDevice): Boolean = runCatching {
            // Hidden-API access is already enabled by Privileged before the transport starts.
            // BluetoothDevice.isEncrypted() accepts encryption on either transport; require LE.
            val service = BluetoothDevice::class.java.getDeclaredMethod("getService")
                .apply { isAccessible = true }.invoke(null)
            val api = Class.forName("android.bluetooth.IBluetooth")
            val names = listOf("getConnectionState", "getConnectionStateWithAttribution")
            val types = arrayOf(BluetoothDevice::class.java, AttributionSource::class.java)
            val read = names.firstNotNullOfOrNull { name -> runCatching { api.getMethod(name, *types) }.getOrNull() }
            val bits = if (read != null) read.invoke(service, device, context.attributionSource) as Int else {
                // Android 13/14 use the same bitmask through an asynchronous result receiver.
                val receiverClass = Class.forName("com.android.modules.utils.SynchronousResultReceiver")
                val receiver = receiverClass.getMethod("get").invoke(null)
                val asyncRead = names.firstNotNullOf { name ->
                    runCatching { api.getMethod(name, *types, receiverClass) }.getOrNull()
                }
                asyncRead.invoke(service, device, context.attributionSource, receiver)
                val result = receiverClass.getMethod("awaitResultNoInterrupt", java.time.Duration::class.java)
                    .invoke(receiver, java.time.Duration.ofSeconds(1))
                result.javaClass.getMethod("getValue", Any::class.java).invoke(result, 0) as Int
            }
            bits and 4 != 0
        }.getOrDefault(false)
    }

    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val subscriptions = context.getSharedPreferences("bluetooth_subscriptions", Context.MODE_PRIVATE)
    private val handler = Handler(Looper.getMainLooper())
    private var started = false
    private var session: Session? = null
    private val retry = Runnable { openSession() }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!started) return
            if (intent.action == BluetoothDevice.ACTION_ENCRYPTION_CHANGE) {
                val device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java) ?: return
                if (intent.getIntExtra(BluetoothDevice.EXTRA_TRANSPORT, 0) == BluetoothDevice.TRANSPORT_LE) {
                    val enabled = intent.getBooleanExtra(BluetoothDevice.EXTRA_ENCRYPTION_ENABLED, false) &&
                        intent.getIntExtra(BluetoothDevice.EXTRA_ENCRYPTION_STATUS, -1) == 0
                    session?.encryptionChanged(device, enabled)
                }
                return
            }
            if (intent.action == BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                val device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java) ?: return
                if (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR) == BluetoothDevice.BOND_NONE) {
                    saveSubscription(device, false)
                    session?.forget(device)
                }
                return
            }
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                    handler.removeCallbacks(retry)
                    stopSession()
                }
                BluetoothAdapter.STATE_ON -> openSession()
            }
        }
    }

    fun start() {
        if (started) return
        started = true
        // Bluetooth broadcasts originate in the privileged Bluetooth process, not the system UID.
        // This is a protected system action; apps cannot spoof it.
        context.registerReceiver(receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED).apply {
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ENCRYPTION_CHANGE)
        }, Context.RECEIVER_EXPORTED)
        openSession()
    }

    // Bonded clients retain their CCCD across reconnects and process/app replacements. macOS may
    // keep the encrypted link and isNotifying=true without writing the descriptor again.
    private fun savedSubscription(device: BluetoothDevice) = device.bondState == BluetoothDevice.BOND_BONDED &&
        device.address in subscriptions.getStringSet("status", emptySet()).orEmpty()

    private fun saveSubscription(device: BluetoothDevice, enabled: Boolean): Boolean {
        val saved = subscriptions.getStringSet("status", emptySet()).orEmpty().toMutableSet()
        if (enabled && device.bondState == BluetoothDevice.BOND_BONDED) saved.add(device.address)
        else saved.remove(device.address)
        // Acknowledge the CCCD only after its durable value is stored (writes are infrequent).
        return subscriptions.edit().putStringSet("status", saved).commit()
    }

    private fun openSession() {
        if (!started || session != null || manager.adapter.state != BluetoothAdapter.STATE_ON) return
        handler.removeCallbacks(retry)
        val next = Session()
        session = next
        runCatching { next.open() }.onFailure {
            Log.w(TAG, "can't open Bluetooth service", it)
            restart(next)
        }
    }

    private fun stopSession() {
        val old = session
        session = null
        old?.close()
        state(false, 0)
    }

    private fun restart(old: Session) {
        if (session !== old) return
        stopSession()
        handler.removeCallbacks(retry)
        if (started) handler.postDelayed(retry, RETRY_MS)
    }

    fun notifySubscribers() {
        handler.post { session?.notifySubscribers() }
    }

    override fun close() {
        if (started) context.unregisterReceiver(receiver)
        started = false
        handler.removeCallbacks(retry)
        stopSession()
    }

    private inner class Session : AutoCloseable {
        @Volatile private var active = true
        private lateinit var server: BluetoothGattServer
        private var advertiser: BluetoothLeAdvertiser? = null
        private var advertisement: AdvertisingSetCallback? = null
        private var advertising = false
        private var serviceReady = false
        // Accessed only on the main handler, including all GATT callbacks below.
        private val subscribers = mutableSetOf<BluetoothDevice>()
        private val connected = mutableSetOf<BluetoothDevice>()
        private val verifiedEncrypted = mutableSetOf<BluetoothDevice>()
        private val statusChar = BluetoothGattCharacteristic(
            STATUS, BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED,
        ).apply {
            addDescriptor(BluetoothGattDescriptor(CCCD,
                BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED or BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED))
        }
        private val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply {
            addCharacteristic(statusChar)
            addCharacteristic(BluetoothGattCharacteristic(COMMAND, BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED))
            addCharacteristic(BluetoothGattCharacteristic(CREDENTIALS, BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED))
        }
        private val serviceDeadline = Runnable { if (active) restart(this) }
        private val advertiseRetry = Runnable { if (active) startAdvertising() }

        fun open() {
            server = requireNotNull(manager.openGattServer(context, callback)) { "GATT server unavailable" }
            check(server.addService(service)) { "GATT service registration rejected" }
            // Some stacks drop the registration callback; don't advertise an absent service.
            handler.postDelayed(serviceDeadline, RETRY_MS)
        }

        private fun publish() { if (active) state(advertising, connected.size) }

        fun forget(device: BluetoothDevice) { subscribers.remove(device); verifiedEncrypted.remove(device) }

        fun encryptionChanged(device: BluetoothDevice, enabled: Boolean) {
            verifiedEncrypted.remove(device)
            // Recheck the live link: a delayed broadcast from an old connection cannot authorise it.
            if (enabled && device in subscribers) notifySubscribers()
        }

        private fun stopAdvertising() {
            val old = advertisement
            advertisement = null // Invalidate before stop can deliver its callback.
            if (old != null) runCatching { advertiser?.stopAdvertisingSet(old) }
            advertising = false
        }

        private fun startAdvertising() {
            if (!active) return
            handler.removeCallbacks(advertiseRetry)
            stopAdvertising()
            publish()
            advertiser = manager.adapter.bluetoothLeAdvertiser
            val next = object : AdvertisingSetCallback() {
                override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, result: Int) {
                    handler.post {
                        if (!active || advertisement !== this) return@post
                        advertising = result == ADVERTISE_SUCCESS
                        publish()
                        if (advertising) handler.removeCallbacks(advertiseRetry)
                        else Log.w(TAG, "advertising failed: $result")
                    }
                }

                override fun onAdvertisingSetStopped(set: AdvertisingSet?) {
                    handler.post {
                        if (!active || advertisement !== this) return@post
                        advertising = false
                        publish()
                        handler.removeCallbacks(advertiseRetry)
                        handler.postDelayed(advertiseRetry, RETRY_MS)
                    }
                }
            }
            advertisement = next
            runCatching {
                advertiser?.startAdvertisingSet(
                    AdvertisingSetParameters.Builder().setLegacyMode(true).setConnectable(true).setScannable(true)
                        .setInterval(AdvertisingSetParameters.INTERVAL_HIGH)
                        .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM).build(),
                    AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(),
                    null, null, null, next,
                )
            }.onFailure { Log.w(TAG, "can't advertise Bluetooth service", it) }
            // Only runs until advertising succeeds; no polling while healthy.
            handler.postDelayed(advertiseRetry, RETRY_MS)
        }

        fun notifySubscribers() {
            if (!active || !serviceReady || subscribers.isEmpty()) return
            work(status) { value ->
                subscribers.filter { it in connected && (it in verifiedEncrypted || linkEncrypted(it)) }
                    .forEach { server.notifyCharacteristicChanged(it, statusChar, false, value) }
            }
        }

        private fun work(read: () -> ByteArray, reply: (ByteArray) -> Unit) {
            worker.execute {
                if (!active) return@execute
                runCatching(read).onSuccess { value ->
                    handler.post { if (active) reply(value) }
                }.onFailure { Log.w(TAG, "Bluetooth read failed", it) }
            }
        }

        override fun close() {
            active = false
            handler.removeCallbacks(serviceDeadline)
            handler.removeCallbacks(advertiseRetry)
            stopAdvertising()
            if (::server.isInitialized) runCatching { server.close() }
            subscribers.clear()
            connected.clear()
            verifiedEncrypted.clear()
        }

        private val callback = object : BluetoothGattServerCallback() {
            override fun onServiceAdded(result: Int, service: BluetoothGattService) {
                handler.post {
                    if (!active) return@post
                    handler.removeCallbacks(serviceDeadline)
                    if (result == BluetoothGatt.GATT_SUCCESS) {
                        serviceReady = true
                        startAdvertising()
                        notifySubscribers()
                    } else restart(this@Session)
                }
            }

            override fun onConnectionStateChange(device: BluetoothDevice, result: Int, newState: Int) {
                handler.post {
                    if (!active) return@post
                    if (newState == BluetoothProfile.STATE_CONNECTED && result == BluetoothGatt.GATT_SUCCESS) {
                        connected.add(device)
                        if (savedSubscription(device)) {
                            subscribers.add(device)
                            notifySubscribers()
                        }
                    }
                    else { connected.remove(device); subscribers.remove(device); verifiedEncrypted.remove(device) }
                    publish()
                }
            }

            override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
                handler.post {
                    if (!active) return@post
                    val read = when (characteristic.uuid) { STATUS -> status; CREDENTIALS -> credentials; else -> null }
                    // Android delivers these reads only after enforcing PERMISSION_READ_ENCRYPTED.
                    if (read != null) verifiedEncrypted.add(device)
                    if (read == null) {
                        server.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                    } else work(read) { value ->
                        val ok = offset in 0..value.size
                        server.sendResponse(device, requestId,
                            if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INVALID_OFFSET,
                            offset, if (ok) value.copyOfRange(offset, value.size) else null)
                    }
                }
            }

            override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
                handler.post {
                    if (!active) return@post
                    val ok = characteristic.uuid == COMMAND && value.size == 1 && value[0] in listOf<Byte>(1, 2)
                    if (responseNeeded) server.sendResponse(device, requestId,
                        if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null)
                    if (ok) worker.execute { if (active) command(value[0]) }
                }
            }

            override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
                handler.post {
                    if (!active) return@post
                    val enabled = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    val valid = descriptor.uuid == CCCD && descriptor.characteristic.uuid == STATUS &&
                        !preparedWrite && offset == 0 && (enabled || value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE))
                    val ok = valid && saveSubscription(device, enabled)
                    if (ok) {
                        // The stack enforces the descriptor's encrypted-write permission first.
                        verifiedEncrypted.add(device)
                        if (enabled) subscribers.add(device) else subscribers.remove(device)
                    }
                    if (responseNeeded) server.sendResponse(device, requestId,
                        if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null)
                }
            }

            override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) {
                handler.post {
                    if (!active) return@post
                    val value = if (device in subscribers || savedSubscription(device)) byteArrayOf(1, 0) else byteArrayOf(0, 0)
                    val valid = descriptor.uuid == CCCD && descriptor.characteristic.uuid == STATUS && offset in 0..value.size
                    server.sendResponse(device, requestId,
                        if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                        offset, if (valid) value.copyOfRange(offset, value.size) else null)
                }
            }
        }
    }
}
