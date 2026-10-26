package ie.xav.tetherbug

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class AutoStartTest {
    private lateinit var app: Application

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences("tetherbug", Context.MODE_PRIVATE).edit().clear().commit()
        shadowOf(app).grantPermissions(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
    }

    @Test fun bootRestartsServiceWithNotificationsDisabled() {
        AutoStart.Receiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertEquals(TetherService::class.java.name, shadowOf(app).nextStartedService?.component?.className)
    }

    @Test fun updateRestartsServiceWithNotificationsDisabled() {
        AutoStart.Receiver().onReceive(app, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
        assertEquals(TetherService::class.java.name, shadowOf(app).nextStartedService?.component?.className)
    }

    @Test fun explicitStopRemainsStoppedAfterBoot() {
        AutoStart.set(app, false)
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        AutoStart.Receiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun missingBluetoothPermissionDoesNotStartService() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        shadowOf(app).denyPermissions(Manifest.permission.BLUETOOTH_ADVERTISE)
        AutoStart.Receiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertNull(shadowOf(app).nextStartedService)
    }
}
