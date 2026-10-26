package ie.xav.tetherbug

import androidx.compose.foundation.lazy.rememberLazyListState
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The Play Store screenshots, drawn on the JVM from placeholder data. Regenerate them into
 * assets/store/android/ with `./gradlew recordRoborazziDebug`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
// A Pixel 7's screen (1080x2400) in dark mode.
@Config(sdk = [36], qualifiers = "w411dp-h914dp-normal-long-notround-night-420dpi-keyshidden-nonav")
class ScreenshotTest {
    // Every setup step done, the Mac connected and the hotspot on.
    private val state =
        SetupUiState(
            permissionsGranted = true,
            shizukuRunning = true,
            shizukuReady = true,
            service = TetherState.Snapshot(running = true, advertising = true, hotspot = 2, connectedMacs = 1),
            pairedMacs = listOf("MacBook"),
            appleIe = true,
            theme = ThemeStyle.PURPLE,
            iconStyle = AppIcon.Style.PURPLE,
            version = "1.0.0",
        )

    private fun capture(name: String, firstItem: Int, offset: Int = 0) =
        captureRoboImage("../assets/store/android/$name.png") {
            Theme(ThemeStyle.PURPLE) { SetupContent(state, SetupActions(), rememberLazyListState(firstItem, offset)) }
        }

    @Test fun setup() = capture("1-setup", 0)

    // From the "Hotspot" title, just below the compact bar (64dp at 420dpi, plus a gap).
    @Test fun hotspot() = capture("2-hotspot", 7, -200)
}
