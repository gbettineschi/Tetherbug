package ie.xav.tetherbug

import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Binder
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.util.concurrent.Executor
import org.lsposed.hiddenapibypass.HiddenApiBypass
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper

/**
 * System calls made through Shizuku as the shell (or root) uid, which holds TETHER_PRIVILEGED
 * and NETWORK_SETTINGS. Hidden APIs are reached reflectively.
 */
internal object Privileged {
    private const val TAG = "tetherbug"
    private const val CONNECTOR = "android.net.ITetheringConnector"
    private const val LISTENER = "android.net.IIntResultListener"
    private const val WIFI_MANAGER = "android.net.wifi.IWifiManager"
    private const val TETHERING_WIFI = 0
    private const val EID_VSA = 221

    // Apple vendor element (OUI 00:17:F2, type 6) that makes macOS treat the hotspot as an
    // iPhone Personal Hotspot.
    private val APPLE_PERSONAL_HOTSPOT =
        byteArrayOf(0x00, 0x17, 0xF2.toByte(), 0x06, 0x01, 0x01, 0x03, 0x01, 0x00, 0x00)

    init {
        HiddenApiBypass.addHiddenApiExemptions("")
    }

    fun isReady(): Boolean =
        Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED

    /** WifiManager#getWifiApState (hidden; needs only ACCESS_WIFI_STATE). */
    fun apState(wifiManager: WifiManager): Int =
        runCatching { WifiManager::class.java.getMethod("getWifiApState").invoke(wifiManager) as Int }.getOrDefault(0)

    // TetheringService checks the caller package against the uid; AppOps resolves "root" to 0.
    private fun callerPkg() = if (Shizuku.getUid() == 0) "root" else "com.android.shell"

    private fun service(name: String, iface: String): Any {
        val binder = requireNotNull(SystemServiceHelper.getSystemService(name)) { "$name unavailable" }
        return Class.forName("$iface\$Stub")
            .getMethod("asInterface", IBinder::class.java)
            .invoke(null, ShizukuBinderWrapper(binder))!!
    }

    private fun call(target: Any, iface: String, name: String, types: Array<Class<*>>, vararg args: Any?): Any? {
        val method = Class.forName(iface).getMethod(name, *types)
        try {
            return method.invoke(target, *args)
        } catch (e: InvocationTargetException) {
            throw (e.cause as? Exception ?: e)
        }
    }

    /** Starts or stops Wi-Fi tethering; [onResult] gets the tethering result code (0 = ok). */
    fun setHotspot(enabled: Boolean, onResult: (Int) -> Unit) {
        val connector = service("tethering", CONNECTOR)
        val listenerClass = Class.forName(LISTENER)
        val listener = resultListener(listenerClass, onResult)
        val string = String::class.java
        val int = Int::class.javaPrimitiveType!!
        val pkg = callerPkg()
        if (enabled) {
            val request =
                Class.forName("android.net.TetheringManager\$TetheringRequest\$Builder")
                    .getConstructor(int)
                    .newInstance(TETHERING_WIFI)
                    .let { it.javaClass.getMethod("build").invoke(it)!! }
            val parcel = request.javaClass.getMethod("getParcel").invoke(request)!!
            call(connector, CONNECTOR, "startTethering", arrayOf(parcel.javaClass, string, string, listenerClass), parcel, pkg, null, listener)
        } else {
            call(connector, CONNECTOR, "stopTethering", arrayOf(int, string, string, listenerClass), TETHERING_WIFI, pkg, null, listener)
        }
    }

    private fun softApConfig(wifi: Any): Any = call(wifi, WIFI_MANAGER, "getSoftApConfiguration", arrayOf())!!

    fun ssid(): String? {
        val config = softApConfig(service("wifi", WIFI_MANAGER))
        return config.javaClass.getMethod("getWifiSsid").invoke(config)?.toString()?.removeSurrounding("\"")
    }

    /** The hotspot's passphrase (empty for an open network). */
    fun passphrase(): String {
        val config = softApConfig(service("wifi", WIFI_MANAGER))
        return config.javaClass.getMethod("getPassphrase").invoke(config) as String? ?: ""
    }

    fun hasAppleIe(): Boolean {
        val config = softApConfig(service("wifi", WIFI_MANAGER))
        @Suppress("UNCHECKED_CAST")
        val elements = config.javaClass.getMethod("getVendorElements").invoke(config) as List<ScanResult.InformationElement>
        return elements.any { it.id == EID_VSA && it.bytes.let { b -> b.remaining() >= 4 && b.get(0) == 0x00.toByte() && b.get(1) == 0x17.toByte() && b.get(2) == 0xF2.toByte() } }
    }

    /** Adds or removes the Apple vendor element; takes effect on the next hotspot start. */
    fun setAppleIe(enabled: Boolean): Boolean = updateSoftApConfig { builderClass, builder ->
        val elements = if (enabled) listOf(ScanResult.InformationElement(EID_VSA, 0, APPLE_PERSONAL_HOTSPOT)) else emptyList()
        builderClass.getMethod("setVendorElements", List::class.java).invoke(builder, elements)
    }

    /** Android's auto-off timeout in whole minutes, 0 when auto-off is off, or null for anything else. */
    fun autoOffMinutes(): Int? {
        val config = softApConfig(service("wifi", WIFI_MANAGER))
        if (!(config.javaClass.getMethod("isAutoShutdownEnabled").invoke(config) as Boolean)) return 0
        val millis = config.javaClass.getMethod("getShutdownTimeoutMillis").invoke(config) as Long
        return if (millis > 0 && millis % 60_000 == 0L) (millis / 60_000).toInt() else null
    }

    /**
     * Android turns the hotspot off once nothing has been connected for its shutdown timeout. Sets
     * that timeout in minutes; 0 turns auto-off off.
     */
    fun setAutoOffMinutes(minutes: Int): Boolean = updateSoftApConfig { builderClass, builder ->
        builderClass.getMethod("setAutoShutdownEnabled", Boolean::class.java).invoke(builder, minutes > 0)
        if (minutes > 0) builderClass.getMethod("setShutdownTimeoutMillis", Long::class.java).invoke(builder, minutes * 60_000L)
    }

    /**
     * Calls [onFrequency] on [executor] with the running hotspot's frequency in MHz (0 while it's
     * off), once right away and again whenever it changes. Uses WifiManager's own SoftApCallback
     * plumbing on a WifiManager bound to the shell-uid binder, since registering needs
     * NETWORK_SETTINGS. Returns a function that unregisters.
     */
    fun watchFrequency(context: Context, executor: Executor, onFrequency: (Int) -> Unit): () -> Unit {
        // (Context, IWifiManager) on current Android; older releases also take a Looper.
        val constructor =
            WifiManager::class.java.declaredConstructors.first { it.parameterTypes.take(2) == listOf(Context::class.java, Class.forName(WIFI_MANAGER)) }
        constructor.isAccessible = true
        val wifi = service("wifi", WIFI_MANAGER)
        val manager = if (constructor.parameterCount == 3) constructor.newInstance(context, wifi, context.mainLooper) else constructor.newInstance(context, wifi)
        val callbackClass = Class.forName("android.net.wifi.WifiManager\$SoftApCallback")
        val frequency = { info: Any? -> info?.let { it.javaClass.getMethod("getFrequency").invoke(it) as Int } ?: 0 }
        val callback =
            Proxy.newProxyInstance(javaClass.classLoader, arrayOf(callbackClass)) { proxy, method, args ->
                when (method.name) {
                    // onInfoChanged(List<SoftApInfo>), one per band when bridged, and the older
                    // onInfoChanged(SoftApInfo); either works, as the Mac needs only one channel.
                    "onInfoChanged" -> onFrequency((args[0] as? List<*> ?: listOf(args[0])).map(frequency).firstOrNull { it > 0 } ?: 0)
                    "hashCode" -> return@newProxyInstance System.identityHashCode(proxy)
                    "equals" -> return@newProxyInstance proxy === args?.firstOrNull()
                    "toString" -> return@newProxyInstance "SoftApCallback"
                }
                null
            }
        WifiManager::class.java.getMethod("registerSoftApCallback", Executor::class.java, callbackClass).invoke(manager, executor, callback)
        return { WifiManager::class.java.getMethod("unregisterSoftApCallback", callbackClass).invoke(manager, callback) }
    }

    private fun updateSoftApConfig(edit: (Class<*>, Any) -> Unit): Boolean {
        val wifi = service("wifi", WIFI_MANAGER)
        val configClass = Class.forName("android.net.wifi.SoftApConfiguration")
        val builderClass = Class.forName("android.net.wifi.SoftApConfiguration\$Builder")
        val builder = builderClass.getConstructor(configClass).newInstance(softApConfig(wifi))
        edit(builderClass, builder)
        val updated = builderClass.getMethod("build").invoke(builder)
        return call(wifi, WIFI_MANAGER, "setSoftApConfiguration", arrayOf(configClass, String::class.java), updated, "com.android.shell") as Boolean
    }

    private fun resultListener(listenerClass: Class<*>, onResult: (Int) -> Unit): Any {
        val binder =
            object : Binder() {
                override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                    if (code != FIRST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
                    data.enforceInterface(LISTENER)
                    val result = data.readInt()
                    Log.d(TAG, "tethering result $result")
                    onResult(result)
                    return true
                }
            }.apply { attachInterface(null, LISTENER) }
        return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(listenerClass)) { proxy, method, args ->
            when (method.name) {
                "asBinder" -> binder
                "hashCode" -> binder.hashCode()
                "equals" -> proxy === args?.firstOrNull()
                "toString" -> LISTENER
                else -> null
            }
        }
    }
}
