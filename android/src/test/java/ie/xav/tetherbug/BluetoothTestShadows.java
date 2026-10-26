package ie.xav.tetherbug;

import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.Context;
import java.util.ArrayList;
import java.util.List;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadows.ShadowBluetoothManager;
import org.robolectric.shadows.ShadowBluetoothLeAdvertiser;
import org.robolectric.shadows.ShadowBluetoothGattServer;
import java.util.HashSet;
import java.util.Set;

/** Records the external Bluetooth boundary while retaining Robolectric's real GATT model. */
public final class BluetoothTestShadows {
    public static final List<BluetoothGattServer> servers = new ArrayList<>();
    public static final List<AdvertisingSetCallback> advertisements = new ArrayList<>();
    public static final List<AdvertisingSetCallback> stoppedAdvertisements = new ArrayList<>();
    public record Notification(BluetoothDevice device, byte[] value) {}
    public static final List<Notification> notifications = new ArrayList<>();
    public static final Set<BluetoothDevice> encrypted = new HashSet<>();

    @Implements(BluetoothGattServer.class)
    public static class Server extends ShadowBluetoothGattServer {
        @Implementation
        protected int notifyCharacteristicChanged(BluetoothDevice device, BluetoothGattCharacteristic characteristic, boolean confirm, byte[] value) {
            notifications.add(new Notification(device, value.clone()));
            return BluetoothStatusCodes.SUCCESS;
        }
    }

    @Implements(BluetoothManager.class)
    public static class Manager extends ShadowBluetoothManager {
        @Override @Implementation
        protected BluetoothGattServer openGattServer(Context context, BluetoothGattServerCallback callback, int transport, boolean eatt) {
            BluetoothGattServer server = super.openGattServer(context, callback, transport, eatt);
            servers.add(server);
            return server;
        }
    }

    @Implements(BluetoothLeAdvertiser.class)
    public static class Advertiser extends ShadowBluetoothLeAdvertiser {
        @Implementation
        protected void startAdvertisingSet(AdvertisingSetParameters parameters, AdvertiseData data, AdvertiseData scanResponse, PeriodicAdvertisingParameters periodic, AdvertiseData periodicData, AdvertisingSetCallback callback) {
            advertisements.add(callback);
        }
        @Implementation
        protected void stopAdvertisingSet(AdvertisingSetCallback callback) {
            stoppedAdvertisements.add(callback);
        }
    }
}
