package com.lab.pm25_capture

import android.Manifest
import android.content.pm.PackageManager
import android.os.StatFs
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.lifecycle.ProcessCameraProvider
import android.util.Rational
import android.content.res.Configuration
import android.view.Surface
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var provider: ProcessCameraProvider? = null
    private var boundCamera: Camera? = null
    private var texture: TextureRegistry.SurfaceTextureEntry? = null
    private var pending: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var frameMs = 0L
    private var previewCrop: List<Double>? = null
    private var cropWidth = 9
    private var cropHeight = 16
    private var bufferTurns = 0
    private var previewUseCase: Preview? = null
    private var detail = "尚未打开后置相机"
    @Volatile private var generation = 0
    @Volatile private var latest: LumaFrame? = null
    @Volatile private var modelAvailable = false
    @Volatile private var modelProblem: String? = null
    private var model: RecModel? = null
    private var probeRunning = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        worker.execute {
            try { model = RecModel(assets); modelAvailable = true }
            catch (e: Exception) { modelProblem = e.message }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pm25_capture/camera")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    if (pending != null) result.error("busy", "相机正在打开", null)
                    else {
                        pending = result
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(Manifest.permission.CAMERA), 41)
                        } else openCamera(flutterEngine.renderer)
                    }
                }
                "state" -> result.success(report())
                "tune" -> tune(call.arguments as? Map<*, *>, result)
                "probe" -> {
                    val roi = call.arguments as? Map<*,*>
                    val frame = latest
                    if (!modelAvailable || roi == null || frame == null || System.currentTimeMillis()-frame.timestamp > 1500)
                        result.error("probe_unavailable", modelProblem ?: "没有可供识别的新鲜帧或模型", null)
                    else if (probeRunning) result.error("busy", "识别测试运行中", null)
                    else {
                        probeRunning = true
                        worker.execute {
                            val reading = model?.recognize(frame, roi)
                            runOnUiThread { probeRunning = false; result.success(reading) }
                        }
                    }
                }
                "sample" -> result.error("unsupported_profile", "尚未登记经验证的 REC 模型、相机模式及 AF/AE 锁定路径", null)
                "close" -> { closeCamera(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun report(): Map<String, Any?> {
        val storage = runCatching { StatFs(filesDir.absolutePath).availableBytes >= 100L * 1024 * 1024 }.getOrDefault(false)
        // The analysis/ROI coordinate system stays locked to rotation 0.
        // The preview texture and the editable ROI share the same display delta.
        val display = displayRotation()
        val cameraInfo = boundCamera?.cameraInfo
        val turns = if (cameraInfo == null) 0 else Math.floorMod(
            cameraInfo.getSensorRotationDegrees(display) -
                cameraInfo.getSensorRotationDegrees(Surface.ROTATION_0), 360) / 90
        val swap = (turns + bufferTurns) % 2 != 0
        return mapOf("textureId" to if (previewCrop != null) texture?.id() else null,
            "width" to if (swap) cropHeight else cropWidth, "height" to if (swap) cropWidth else cropHeight,
            "turns" to turns, "bufferTurns" to bufferTurns, "crop" to previewCrop,
            "modelAvailable" to modelAvailable,
            "platform" to "Android CameraX", "device" to android.os.Build.MODEL,
            "framesReady" to (frameMs > 0 && System.currentTimeMillis() - frameMs < 1500),
            "storageReady" to storage, "validated" to false, "ready" to false, "roiLimit" to 0,
            "periods" to emptyList<Int>(), "tuneSupported" to (boundCamera != null), "probeSupported" to modelAvailable, "message" to detail)
    }

    private fun finishOpen() { pending?.success(report()); pending = null }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 41 || pending == null) return
        val renderer = flutterEngine?.renderer
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && renderer != null) openCamera(renderer)
        else { detail = "相机权限未授权"; finishOpen() }
    }

    private fun openCamera(registry: TextureRegistry) {
        val token = ++generation
        val future = ProcessCameraProvider.getInstance(this)
        val main = ContextCompat.getMainExecutor(this)
        future.addListener({
            if (generation != token || pending == null) return@addListener
            try {
                val cameras = future.get().also { provider = it }
                val selector = CameraSelector.DEFAULT_BACK_CAMERA
                require(cameras.hasCamera(selector)) { "未找到后置相机" }
                // Keep a single rotation-0 CameraX viewport for preview, saved ROIs and analysis.
                // Use a SurfaceTexture explicitly so Dart owns the CameraX crop and sensor rotation.
                val entry = registry.createSurfaceTexture().also { texture = it }
                val display = displayRotation()
                val sideways = display == Surface.ROTATION_90 || display == Surface.ROTATION_270
                val naturalLandscape = (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) != sideways
                val ratio = if (naturalLandscape) Rational(16, 9) else Rational(9, 16)
                val rotation = Surface.ROTATION_0
                val preview = Preview.Builder().setTargetRotation(rotation).build().also { useCase ->
                    useCase.setSurfaceProvider { request ->
                        if (texture !== entry) request.willNotProvideSurface()
                        else {
                            val resolution = request.resolution
                            entry.surfaceTexture().setDefaultBufferSize(resolution.width, resolution.height)
                            request.setTransformationInfoListener(main) { info ->
                                if (texture === entry) {
                                    val rect = info.cropRect
                                    cropWidth = rect.width()
                                    cropHeight = rect.height()
                                    bufferTurns = info.rotationDegrees / 90
                                    previewCrop = listOf(rect.left.toDouble()/resolution.width,
                                        rect.top.toDouble()/resolution.height, rect.width().toDouble()/resolution.width,
                                        rect.height().toDouble()/resolution.height)
                                }
                            }
                            val surface = Surface(entry.surfaceTexture())
                            request.provideSurface(surface, main) { surface.release() }
                        }
                    }
                }
                previewUseCase = preview
                @Suppress("DEPRECATION")
                val analysis = ImageAnalysis.Builder().setTargetResolution(Size(1280,720)).setTargetRotation(rotation)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysis.setAnalyzer(worker) { proxy ->
                    try {
                        val now = System.currentTimeMillis()
                        if (generation == token) {
                            if (modelAvailable && now - (latest?.timestamp ?: 0L) >= 100) {
                                val frame = runCatching { LumaFrame.from(proxy, now) }.getOrNull()
                                if (generation == token) latest = frame
                            }
                            frameMs = now
                        }
                    } finally { proxy.close() }
                }
                val viewPort = ViewPort.Builder(ratio, rotation).setScaleType(ViewPort.FILL_CENTER).build()
                val group = UseCaseGroup.Builder().setViewPort(viewPort).addUseCase(preview).addUseCase(analysis).build()
                val camera = cameras.bindToLifecycle(this,selector,group)
                boundCamera = camera
                camera.cameraInfo.cameraState.observe(this) { state ->
                    if (generation == token && state.error != null) detail = "CameraX 相机错误：${state.error?.code}"
                    else if (generation == token && state.type == CameraState.Type.OPEN) detail = "后置相机已连接"
                }
                detail = "后置相机已连接"
                finishOpen()
            } catch (e: Exception) {
                detail = "相机启动失败：${e.message}"
                closeCamera(resetDetail = false)
            }
        },main)
    }

    @Suppress("DEPRECATION")
    private fun tune(roi: Map<*, *>?, result: MethodChannel.Result) {
        val camera = boundCamera
        if (camera == null || roi == null) { result.error("not_ready", "相机未就绪", null); return }
        val make = {
            val u = (((roi["l"] as Number).toFloat() + (roi["r"] as Number).toFloat()) / 2)
            val v = (((roi["t"] as Number).toFloat() + (roi["b"] as Number).toFloat()) / 2)
            require(u in 0f..1f && v in 0f..1f)
            val crop = requireNotNull(previewCrop)
            val (x, y) = when (bufferTurns) {
                1 -> v to 1-u
                2 -> 1-u to 1-v
                3 -> 1-v to u
                else -> u to v
            }
            val point = SurfaceOrientedMeteringPointFactory(1f, 1f, requireNotNull(previewUseCase))
                .createPoint((crop[0]+x*crop[2]).toFloat(), (crop[1]+y*crop[3]).toFloat())
            FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE).build()
        }
        try {
            val action = make()
            if (!camera.cameraInfo.isFocusMeteringSupported(action)) {
                detail = "该相机不支持 ROI 点调焦/测光，真实采集仍禁用"
                result.success(report()); return
            }
            val token = generation
            val future = camera.cameraControl.startFocusAndMetering(action)
            val handler = android.os.Handler(mainLooper)
            var waiting = true
            handler.postDelayed({
                if (waiting) {
                    waiting = false
                    if (token == generation) {
                        camera.cameraControl.cancelFocusAndMetering()
                        detail = "ROI 调优超时；AF/AE 未确认锁定"
                    }
                    result.success(report())
                }
            }, 2000)
            future.addListener({
                if (waiting) {
                    waiting = false
                    if (token == generation) {
                        val focused = runCatching { future.get().isFocusSuccessful }.getOrDefault(false)
                        detail = if (focused) "相机报告对焦成功；AE/锁定未确认，真实采集仍禁用"
                            else "相机未确认对焦成功或锁定，真实采集仍禁用"
                    }
                    result.success(report())
                }
            }, ContextCompat.getMainExecutor(this))
        } catch (e: Exception) { result.error("tune_failed", e.message, null) }
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int = windowManager.defaultDisplay.rotation

    private fun closeCamera(resetDetail: Boolean = true) {
        generation++
        provider?.unbindAll()
        boundCamera = null
        texture?.release()
        texture = null
        previewUseCase = null
        previewCrop = null
        frameMs = 0
        latest = null
        if (resetDetail) detail = "相机已关闭"
        finishOpen()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        closeCamera()
        channel?.setMethodCallHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }
    override fun onDestroy() {
        closeCamera()
        worker.execute { model?.close(); model = null }
        worker.shutdown()
        super.onDestroy()
    }
}
