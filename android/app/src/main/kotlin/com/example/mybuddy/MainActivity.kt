package com.example.mybuddy

import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.BatteryManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import com.unity3d.player.UnityPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "unity_bridge"

    // Per-turn battery telemetry for the E1/E2/E3 protocol (section 1b).
    private val batteryChannelName = "mybuddy/battery"

    private val defaultGameObjectName = "UnityBridge"

    private lateinit var unityPlayer: UnityPlayer
    private val mainHandler = Handler(Looper.getMainLooper())
    private val bootCommandDelayMs = 600L

    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun getTransparencyMode(): TransparencyMode = TransparencyMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        unityPlayer = UnityPlayer(this)

        val root = findViewById<FrameLayout>(android.R.id.content)
        root.addView(
            unityPlayer,
            0,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        unityPlayer.requestFocus()

        mainHandler.post { forceFlutterOverlayOnTop() }
        mainHandler.postDelayed({ forceFlutterOverlayOnTop() }, 300L)
        mainHandler.postDelayed({ forceFlutterOverlayOnTop() }, 900L)
        mainHandler.postDelayed({ forceFlutterOverlayOnTop() }, 1500L)
        mainHandler.postDelayed({ forceFlutterOverlayOnTop() }, 2200L)
    }

    override fun onPostResume() {
        super.onPostResume()
        mainHandler.post { forceFlutterOverlayOnTop() }
        mainHandler.postDelayed({ forceFlutterOverlayOnTop() }, 600L)
    }

    override fun onResume() {
        super.onResume()
        unityPlayer.onResume()
        mainHandler.post { forceFlutterOverlayOnTop() }
        mainHandler.postDelayed({ forceFlutterOverlayOnTop() }, 400L)
    }

    override fun onPause() {
        unityPlayer.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        unityPlayer.destroy()
        super.onDestroy()
    }

    override fun onLowMemory() {
        super.onLowMemory()
        unityPlayer.lowMemory()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level == TRIM_MEMORY_RUNNING_CRITICAL) {
            unityPlayer.lowMemory()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        unityPlayer.windowFocusChanged(hasFocus)
        if (hasFocus) {
            mainHandler.post { forceFlutterOverlayOnTop() }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openUnity" -> {
                    val args = call.arguments as? Map<*, *>
                    val gameObject = (args?.get("gameObject") as? String)?.takeIf { it.isNotBlank() }
                        ?: defaultGameObjectName
                    val initialSpeakPath = args?.get("initialSpeakPath") as? String

                    val initialAnimIndex = args?.get("initialAnimIndex")
                    val animIndexInt = when (initialAnimIndex) {
                        is Int -> initialAnimIndex
                        is Number -> initialAnimIndex.toInt()
                        else -> null
                    }

                    val initialStopSpeak = args?.get("initialStopSpeak") as? Boolean

                    if (!initialSpeakPath.isNullOrBlank()) {
                        postUnitySendMessage(gameObject, "Speak", initialSpeakPath)
                    }
                    if (initialStopSpeak == true) {
                        postUnitySendMessage(gameObject, "StopSpeak", "")
                    }
                    if (animIndexInt != null && animIndexInt >= 0) {
                        postUnitySendMessage(gameObject, "PlayAnimation", animIndexInt.toString())
                    }

                    result.success(null)
                }

                "unitySpeak" -> {
                    val args = call.arguments as? Map<*, *>
                    val gameObject = (args?.get("gameObject") as? String)?.takeIf { it.isNotBlank() }
                        ?: defaultGameObjectName
                    val path = args?.get("path") as? String
                    if (path.isNullOrBlank()) {
                        result.error("BAD_ARGS", "Missing 'path'", null)
                        return@setMethodCallHandler
                    }

                    try {
                        UnityPlayer.UnitySendMessage(gameObject, "Speak", path)
                        result.success(null)
                    } catch (t: Throwable) {
                        result.error("UNITY_SEND_FAILED", t.message, null)
                    }
                }

                "unityStopSpeak" -> {
                    val args = call.arguments as? Map<*, *>
                    val gameObject = (args?.get("gameObject") as? String)?.takeIf { it.isNotBlank() }
                        ?: defaultGameObjectName

                    try {
                        UnityPlayer.UnitySendMessage(gameObject, "StopSpeak", "")
                        result.success(null)
                    } catch (t: Throwable) {
                        result.error("UNITY_SEND_FAILED", t.message, null)
                    }
                }

                "unityPlayAnimation" -> {
                    val args = call.arguments as? Map<*, *>
                    val gameObject = (args?.get("gameObject") as? String)?.takeIf { it.isNotBlank() }
                        ?: defaultGameObjectName
                    val indexAny = args?.get("index")
                    val indexString = when (indexAny) {
                        is Int -> indexAny.toString()
                        is Number -> indexAny.toInt().toString()
                        is String -> indexAny
                        else -> null
                    }
                    if (indexString.isNullOrBlank()) {
                        result.error("BAD_ARGS", "Missing 'index'", null)
                        return@setMethodCallHandler
                    }

                    try {
                        UnityPlayer.UnitySendMessage(gameObject, "PlayAnimation", indexString)
                        result.success(null)
                    } catch (t: Throwable) {
                        result.error("UNITY_SEND_FAILED", t.message, null)
                    }
                }

                "moveAppToBackground" -> {
                    try {
                        val moved = moveTaskToBack(true)
                        result.success(moved)
                    } catch (t: Throwable) {
                        result.error("MOVE_TO_BACKGROUND_FAILED", t.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            batteryChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> result.success(readBatteryStatus())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Reads battery level and temperature from the sticky ACTION_BATTERY_CHANGED
     * broadcast.
     *
     * Temperature is only available here - BatteryManager exposes no property
     * for it - which is why this cannot be replaced by an off-the-shelf plugin.
     *
     * Returns nulls rather than failing: a missing reading must never abort a
     * turn or drop its log row.
     */
    private fun readBatteryStatus(): Map<String, Any?> {
        return try {
            val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))

            val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val percent = if (level >= 0 && scale > 0) {
                (level * 100.0 / scale).toInt()
            } else {
                null
            }

            // EXTRA_TEMPERATURE is in tenths of a degree Celsius.
            val rawTemp = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
                ?: Int.MIN_VALUE
            val temperatureC = if (rawTemp != Int.MIN_VALUE) rawTemp / 10.0 else null

            mapOf("percent" to percent, "temperatureC" to temperatureC)
        } catch (t: Throwable) {
            mapOf("percent" to null, "temperatureC" to null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        unityPlayer.newIntent(intent)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        unityPlayer.configurationChanged(newConfig)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        return if (event.action == KeyEvent.ACTION_MULTIPLE) {
            unityPlayer.injectEvent(event)
        } else {
            super.dispatchKeyEvent(event)
        }
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        return unityPlayer.onKeyUp(keyCode, event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        return unityPlayer.onKeyDown(keyCode, event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        return unityPlayer.onTouchEvent(event)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        return unityPlayer.onGenericMotionEvent(event)
    }

    private fun postUnitySendMessage(gameObject: String, method: String, param: String) {
        mainHandler.postDelayed(
            {
                try {
                    UnityPlayer.UnitySendMessage(gameObject, method, param)
                } catch (_: Throwable) {
                }
            },
            bootCommandDelayMs,
        )
    }

    private fun forceFlutterOverlayOnTop() {
        val surfaceViews = ArrayList<SurfaceView>(2)
        collectSurfaceViews(unityPlayer, surfaceViews)
        for (sv in surfaceViews) {
            try {
                sv.setZOrderOnTop(false)
                sv.setZOrderMediaOverlay(false)
            } catch (_: Throwable) {
            }
        }

        val root = findViewById<FrameLayout>(android.R.id.content)
        for (i in 0 until root.childCount) {
            val child = root.getChildAt(i)
            if (child !== unityPlayer) {
                child.bringToFront()
            }
        }
        root.invalidate()
        root.requestLayout()
    }

    private fun collectSurfaceViews(view: View, out: MutableList<SurfaceView>) {
        if (view is SurfaceView) {
            out.add(view)
            return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                collectSurfaceViews(view.getChildAt(i), out)
            }
        }
    }
}
