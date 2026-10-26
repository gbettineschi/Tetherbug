package ie.xav.tetherbug

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.AdvertisingSetCallback
import android.content.Context
import android.content.Intent
import android.os.Looper
import java.time.Duration
import java.util.concurrent.Executor
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], shadows = [BluetoothTestShadows.Manager::class, BluetoothTestShadows.Advertiser::class, BluetoothTestShadows.Server::class])
@LooperMode(LooperMode.Mode.PAUSED)
class BluetoothTransportTest {
    private lateinit var context: Context
    private lateinit var adapter: BluetoothAdapter
    private lateinit var transport: BluetoothTransport
    private val work = ArrayDeque<Runnable>()
    private val commands = mutableListOf<Byte>()
    private var advertising = false
    private var connected = 0
    private var statusReads = 0
    private val status = byteArrayOf(3, 0, 81, 2, 1, 0, 0)

    @Before fun setup() {
        val app = RuntimeEnvironment.getApplication()
        context = app
        shadowOf(app).grantPermissions(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        adapter = context.getSystemService(BluetoothManager::class.java).adapter
        shadowOf(adapter).setState(BluetoothAdapter.STATE_ON)
        BluetoothTestShadows.servers.clear()
        BluetoothTestShadows.advertisements.clear()
        BluetoothTestShadows.stoppedAdvertisements.clear()
        BluetoothTestShadows.notifications.clear()
        BluetoothTestShadows.encrypted.clear()
        transport = newTransport()
    }

    private fun newTransport() = BluetoothTransport(context, Executor { work.addLast(it) },
            status = { statusReads++; status.copyOf() },
            credentials = { byteArrayOf(10, 20) },
            command = { commands.add(it) },
            state = { active, count -> advertising = active; connected = count },
            linkEncrypted = { it in BluetoothTestShadows.encrypted })

    @After fun cleanup() { transport.close() }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()
    private fun runWork() { while (work.isNotEmpty()) work.removeFirst().run(); idle() }
    private fun radio(state: Int) {
        shadowOf(adapter).setState(state)
        context.sendBroadcast(Intent(BluetoothAdapter.ACTION_STATE_CHANGED).putExtra(BluetoothAdapter.EXTRA_STATE, state))
        idle()
    }
    private fun ready(server: BluetoothGattServer) {
        shadowOf(server).gattServerCallback.onServiceAdded(BluetoothGatt.GATT_SUCCESS, server.getService(BluetoothTransport.SERVICE))
        idle()
        BluetoothTestShadows.advertisements.last().onAdvertisingSetStarted(null, 0, AdvertisingSetCallback.ADVERTISE_SUCCESS)
        idle()
    }
    private fun device() = adapter.getRemoteDevice("12:34:56:78:90:AB")
    private fun connect(server: BluetoothGattServer, peer: BluetoothDevice = device()) {
        shadowOf(server).gattServerCallback.onConnectionStateChange(peer, 0, BluetoothProfile.STATE_CONNECTED)
        idle(); runWork()
    }
    private fun subscribe(server: BluetoothGattServer, enabled: Boolean = true, peer: BluetoothDevice = device()) {
        shadowOf(server).gattServerCallback.onDescriptorWriteRequest(peer, 9,
            server.getService(BluetoothTransport.SERVICE).getCharacteristic(BluetoothTransport.STATUS).descriptors.single(),
            false, true, 0, if (enabled) byteArrayOf(1, 0) else byteArrayOf(0, 0))
        idle(); runWork()
    }
    private fun replace(): BluetoothGattServer {
        transport.close()
        transport = newTransport()
        transport.start()
        return BluetoothTestShadows.servers.last()
    }
    private fun read(server: BluetoothGattServer) {
        shadowOf(server).gattServerCallback.onCharacteristicReadRequest(device(), 1, 0, server.getService(BluetoothTransport.SERVICE).getCharacteristic(BluetoothTransport.STATUS))
    }

    @Test fun exposesEncryptedStatusAndCommands() {
        transport.start()
        val server = BluetoothTestShadows.servers.single()
        val service = server.getService(BluetoothTransport.SERVICE)
        assertNotNull(service)
        assertEquals(BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED, service.getCharacteristic(BluetoothTransport.STATUS).permissions)
        assertEquals(BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED, service.getCharacteristic(BluetoothTransport.CREDENTIALS).permissions)
        assertEquals(BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED, service.getCharacteristic(BluetoothTransport.COMMAND).permissions)
        assertEquals(BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED or BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED,
            service.getCharacteristic(BluetoothTransport.STATUS).descriptors.single().permissions)
        ready(server)
        assertTrue(advertising)
        read(server); idle(); runWork()
        assertArrayEquals(byteArrayOf(3, 0, 81, 2, 1, 0, 0), shadowOf(server).responses.single())
    }

    @Test fun radioCycleRecreatesServerAndReturnsFreshStatus() {
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old)
        shadowOf(old).gattServerCallback.onConnectionStateChange(device(), 0, BluetoothProfile.STATE_CONNECTED); idle()
        assertEquals(1, connected)
        radio(BluetoothAdapter.STATE_TURNING_OFF)
        assertTrue(shadowOf(old).isClosed)
        assertFalse(advertising)
        assertEquals(0, connected)
        radio(BluetoothAdapter.STATE_OFF)
        radio(BluetoothAdapter.STATE_ON)
        assertEquals(2, BluetoothTestShadows.servers.size)
        val fresh = BluetoothTestShadows.servers.last()
        assertNotSame(old, fresh)
        ready(fresh)
        read(fresh); idle(); runWork()
        assertArrayEquals(byteArrayOf(3, 0, 81, 2, 1, 0, 0), shadowOf(fresh).responses.single())
    }

    @Test fun startsWithRadioOffAndIgnoresDuplicateOn() {
        shadowOf(adapter).setState(BluetoothAdapter.STATE_OFF)
        transport.start()
        assertTrue(BluetoothTestShadows.servers.isEmpty())
        radio(BluetoothAdapter.STATE_ON)
        assertEquals(1, BluetoothTestShadows.servers.size)
        radio(BluetoothAdapter.STATE_ON)
        assertEquals(1, BluetoothTestShadows.servers.size)
    }

    @Test fun staleCallbacksAndQueuedReadsCannotAffectReplacement() {
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old)
        val oldAdvertisement = BluetoothTestShadows.advertisements.single()
        read(old); idle() // request waits in the worker while the adapter restarts
        radio(BluetoothAdapter.STATE_OFF)
        radio(BluetoothAdapter.STATE_ON)
        shadowOf(old).gattServerCallback.onConnectionStateChange(device(), 0, BluetoothProfile.STATE_CONNECTED)
        oldAdvertisement.onAdvertisingSetStarted(null, 0, AdvertisingSetCallback.ADVERTISE_SUCCESS)
        idle(); runWork()
        assertEquals(0, connected)
        assertFalse(advertising)
        assertEquals(0, statusReads)
        assertTrue(shadowOf(old).responses.isEmpty())
        assertTrue(shadowOf(BluetoothTestShadows.servers.last()).responses.isEmpty())
    }

    @Test fun closeCancelsRetriesAndIgnoresLaterRadioEvents() {
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old)
        radio(BluetoothAdapter.STATE_OFF)
        transport.close()
        radio(BluetoothAdapter.STATE_ON)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(20))
        assertEquals(1, BluetoothTestShadows.servers.size)
        assertTrue(shadowOf(old).isClosed)
        assertFalse(advertising)
    }

    @Test fun advertisingFailureRetriesOnlyInTheActiveSession() {
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        shadowOf(old).gattServerCallback.onServiceAdded(0, old.getService(BluetoothTransport.SERVICE)); idle()
        BluetoothTestShadows.advertisements.single().onAdvertisingSetStarted(null, 0, AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR); idle()
        radio(BluetoothAdapter.STATE_OFF)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(10))
        assertEquals(1, BluetoothTestShadows.advertisements.size)
        radio(BluetoothAdapter.STATE_ON)
        ready(BluetoothTestShadows.servers.last())
        assertTrue(advertising)
    }

    @Test fun oldAdvertisingAttemptCannotCompleteANewerAttempt() {
        transport.start()
        val server = BluetoothTestShadows.servers.single()
        shadowOf(server).gattServerCallback.onServiceAdded(0, server.getService(BluetoothTransport.SERVICE)); idle()
        val old = BluetoothTestShadows.advertisements.single()
        old.onAdvertisingSetStarted(null, 0, AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR); idle()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5))
        assertEquals(2, BluetoothTestShadows.advertisements.size)
        old.onAdvertisingSetStarted(null, 0, AdvertisingSetCallback.ADVERTISE_SUCCESS); idle()
        assertFalse(advertising)
        BluetoothTestShadows.advertisements.last().onAdvertisingSetStarted(null, 0, AdvertisingSetCallback.ADVERTISE_SUCCESS); idle()
        assertTrue(advertising)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(20))
        assertEquals(2, BluetoothTestShadows.advertisements.size)
    }

    @Test fun lostRegistrationCallbackRebuildsServer() {
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(10))
        assertTrue(shadowOf(old).isClosed)
        assertEquals(2, BluetoothTestShadows.servers.size)
        val fresh = BluetoothTestShadows.servers.last()
        ready(fresh)
        read(fresh); idle(); runWork()
        assertArrayEquals(byteArrayOf(3, 0, 81, 2, 1, 0, 0), shadowOf(fresh).responses.single())
    }

    @Test fun replacementAcceptsCommandsAndCredentialsButDropsOldQueuedCommand() {
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old)
        fun write(server: BluetoothGattServer, value: Byte) {
            shadowOf(server).gattServerCallback.onCharacteristicWriteRequest(device(), 1,
                server.getService(BluetoothTransport.SERVICE).getCharacteristic(BluetoothTransport.COMMAND),
                false, true, 0, byteArrayOf(value))
            idle()
        }
        write(old, 1)
        radio(BluetoothAdapter.STATE_OFF)
        radio(BluetoothAdapter.STATE_ON)
        val fresh = BluetoothTestShadows.servers.last()
        ready(fresh)
        write(fresh, 2)
        write(fresh, 1)
        write(fresh, 3)
        runWork()
        assertEquals(listOf<Byte>(2, 1), commands)
        shadowOf(fresh).clearResponses()
        shadowOf(fresh).gattServerCallback.onCharacteristicReadRequest(device(), 2, 0,
            fresh.getService(BluetoothTransport.SERVICE).getCharacteristic(BluetoothTransport.CREDENTIALS))
        idle(); runWork()
        assertArrayEquals(byteArrayOf(10, 20), shadowOf(fresh).responses.single())
    }

    @Test fun pairedSubscriptionSurvivesAppReplacementWithoutAnotherDescriptorWrite() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        BluetoothTestShadows.encrypted.add(device())
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old)
        BluetoothTestShadows.notifications.clear()
        val fresh = replace()
        // On the physical phone, connection callbacks arrive before onServiceAdded.
        connect(fresh)
        assertTrue(BluetoothTestShadows.notifications.isEmpty())
        status[2] = 63
        ready(fresh); runWork()
        assertArrayEquals(byteArrayOf(3, 0, 63, 2, 1, 0, 0), BluetoothTestShadows.notifications.single().value())
        BluetoothTestShadows.notifications.clear()
        status[4] = 0
        transport.notifySubscribers(); idle(); runWork()
        assertEquals(device(), BluetoothTestShadows.notifications.single().device())
        assertArrayEquals(byteArrayOf(3, 0, 63, 2, 0, 0, 0), BluetoothTestShadows.notifications.single().value())
    }

    @Test fun pairedReconnectRestoresOnlyTheSubscribedPeer() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        BluetoothTestShadows.encrypted.add(device())
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old)
        val other = adapter.getRemoteDevice("23:45:67:89:01:BC")
        shadowOf(other).setBondState(BluetoothDevice.BOND_BONDED)
        BluetoothTestShadows.encrypted.add(other)
        BluetoothTestShadows.notifications.clear()
        val fresh = replace()
        ready(fresh)
        connect(fresh, other)
        assertTrue(BluetoothTestShadows.notifications.isEmpty())
        connect(fresh)
        assertEquals(device(), BluetoothTestShadows.notifications.single().device())
    }

    @Test fun disabledSubscriptionDoesNotReturnAfterReplacement() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        BluetoothTestShadows.encrypted.add(device())
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old); subscribe(old, false)
        BluetoothTestShadows.notifications.clear()
        val fresh = replace()
        ready(fresh); connect(fresh)
        transport.notifySubscribers(); idle(); runWork()
        assertTrue(BluetoothTestShadows.notifications.isEmpty())
    }

    @Test fun nonBondedSubscriptionIsNotRestored() {
        BluetoothTestShadows.encrypted.add(device())
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old)
        BluetoothTestShadows.notifications.clear()
        val fresh = replace()
        ready(fresh); connect(fresh)
        transport.notifySubscribers(); idle(); runWork()
        assertTrue(BluetoothTestShadows.notifications.isEmpty())
    }

    @Test fun descriptorReadReturnsEachPeersSubscription() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        transport.start()
        val server = BluetoothTestShadows.servers.single()
        ready(server); connect(server); subscribe(server)
        shadowOf(server).clearResponses()
        val cb = shadowOf(server).gattServerCallback
        val descriptor = server.getService(BluetoothTransport.SERVICE).getCharacteristic(BluetoothTransport.STATUS).descriptors.single()
        cb.onDescriptorReadRequest(device(), 10, 0, descriptor)
        cb.onDescriptorReadRequest(adapter.getRemoteDevice("23:45:67:89:01:BC"), 11, 0, descriptor)
        idle()
        assertEquals(2, shadowOf(server).responses.size)
        assertArrayEquals(byteArrayOf(1, 0), shadowOf(server).responses[0])
        assertArrayEquals(byteArrayOf(0, 0), shadowOf(server).responses[1])
    }

    @Test fun restoredSubscriptionWaitsForAnEncryptedLink() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old)
        val fresh = replace()
        ready(fresh); connect(fresh)
        BluetoothTestShadows.notifications.clear()
        transport.notifySubscribers(); idle(); runWork()
        assertTrue(BluetoothTestShadows.notifications.isEmpty())
        BluetoothTestShadows.encrypted.add(device())
        transport.notifySubscribers(); idle(); runWork()
        assertArrayEquals(byteArrayOf(3, 0, 81, 2, 1, 0, 0), BluetoothTestShadows.notifications.single().value())
    }

    @Test fun lateLeEncryptionPublishesRestoredStatusWithoutWaitingForAnotherEvent() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old)
        val fresh = replace()
        ready(fresh); connect(fresh)
        BluetoothTestShadows.notifications.clear()
        BluetoothTestShadows.encrypted.add(device())
        context.sendBroadcast(Intent(BluetoothDevice.ACTION_ENCRYPTION_CHANGE)
            .putExtra(BluetoothDevice.EXTRA_DEVICE, device())
            .putExtra(BluetoothDevice.EXTRA_TRANSPORT, BluetoothDevice.TRANSPORT_LE)
            .putExtra(BluetoothDevice.EXTRA_ENCRYPTION_ENABLED, true)
            .putExtra(BluetoothDevice.EXTRA_ENCRYPTION_STATUS, 0))
        idle(); runWork()
        assertArrayEquals(byteArrayOf(3, 0, 81, 2, 1, 0, 0), BluetoothTestShadows.notifications.single().value())
    }

    @Test fun staleEncryptionBroadcastCannotAuthorizeAnUnencryptedConnection() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old)
        val fresh = replace()
        ready(fresh); connect(fresh)
        context.sendBroadcast(Intent(BluetoothDevice.ACTION_ENCRYPTION_CHANGE)
            .putExtra(BluetoothDevice.EXTRA_DEVICE, device())
            .putExtra(BluetoothDevice.EXTRA_TRANSPORT, BluetoothDevice.TRANSPORT_LE)
            .putExtra(BluetoothDevice.EXTRA_ENCRYPTION_ENABLED, true)
            .putExtra(BluetoothDevice.EXTRA_ENCRYPTION_STATUS, 0))
        idle(); runWork()
        assertTrue(BluetoothTestShadows.notifications.isEmpty())
    }

    @Test fun removingBondForgetsTheSubscriptionEvenIfThePeerPairsAgain() {
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        BluetoothTestShadows.encrypted.add(device())
        transport.start()
        val old = BluetoothTestShadows.servers.single()
        ready(old); connect(old); subscribe(old)
        shadowOf(device()).setBondState(BluetoothDevice.BOND_NONE)
        context.sendBroadcast(Intent(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            .putExtra(BluetoothDevice.EXTRA_DEVICE, device()).putExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE))
        idle()
        shadowOf(device()).setBondState(BluetoothDevice.BOND_BONDED)
        val fresh = replace()
        ready(fresh); connect(fresh)
        BluetoothTestShadows.notifications.clear()
        transport.notifySubscribers(); idle(); runWork()
        assertTrue(BluetoothTestShadows.notifications.isEmpty())
    }
}
