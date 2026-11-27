package com.lab.pm25_capture

import android.Manifest
import android.content.pm.PackageManager
import android.os.StatFs
import android.os.SystemClock
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import org.json.JSONArray
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

@ExperimentalCamera2Interop
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var provider: ProcessCameraProvider? = null
    private var boundCamera: Camera? = null
    private var texture: TextureRegistry.SurfaceTextureEntry? = null
    private var pending: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val analysisWorker = Executors.newSingleThreadExecutor()
    private val handler by lazy { android.os.Handler(mainLooper) }
    @Volatile private var af: Int? = null
    @Volatile private var ae: Int? = null
    @Volatile private var tuned = false
    private var tuning = false
    private var tuneGeneration = 0
    private val locked get() = tuned && af == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED && ae == CaptureResult.CONTROL_AE_STATE_LOCKED
    private val profiles by lazy {
        runCatching { JSONArray(assets.open("accepted-profiles.json").bufferedReader().use { it.readText() }) }.getOrElse { JSONArray() }
    }
    private fun capacities(): Map<String, Int> {
        val frame = latest ?: return emptyMap()
        val current = if (modelAvailable) model ?: return emptyMap() else return emptyMap()
        val camera = boundCamera ?: return emptyMap()
        val cameraId = Camera2CameraInfo.from(camera.cameraInfo).cameraId
        val capacities = mutableMapOf<String, Int>()
        for (i in 0 until profiles.length()) {
            val item = profiles.optJSONObject(i) ?: continue
            if (item.optString("fingerprint") != android.os.Build.FINGERPRINT ||
                item.optString("cameraId") != cameraId || item.optString("modelSha256") != current.sha256 ||
                item.optString("runtimeVersion") != "1.22.0" ||
                item.optInt("width") != frame.uprightWidth || item.optInt("height") != frame.uprightHeight) continue
            val period = item.optInt("periodMs")
            val count = item.optInt("roiCount")
            if (period in listOf(1000, 2000, 5000) && count in 1..8) capacities["$period:$count"] = count
        }
        return capacities
    }
    private fun storageReady() = runCatching { StatFs(filesDir.absolutePath).availableBytes >= 100L * 1024 * 1024 }.getOrDefault(false)
    private fun freshFrame() = frameMs > 0 && SystemClock.elapsedRealtime() - frameMs < 1500

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
                "sample" -> sample(call.arguments as? Map<*, *>, result)
                "close" -> { closeCamera(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun report(): Map<String, Any?> {
        val storage = storageReady()
        val capacities = capacities()
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
            "modelAvailable" to modelAvailable, "modelProblem" to modelProblem,
            "modelVersion" to model?.version, "modelSha256" to model?.sha256, "runtimeVersion" to "1.22.0",
            "sessionId" to generation, "afState" to af, "aeState" to ae, "locked" to locked,
            "cameraId" to cameraInfo?.let { Camera2CameraInfo.from(it).cameraId },
            "fingerprint" to android.os.Build.FINGERPRINT, "analysisWidth" to latest?.uprightWidth, "analysisHeight" to latest?.uprightHeight,
            "platform" to "Android CameraX", "device" to android.os.Build.MODEL,
            "framesReady" to freshFrame(),
            "storageReady" to storage, "validated" to capacities.isNotEmpty(), "ready" to locked, "profiles" to capacities,
            "periods" to capacities.keys.map { it.substringBefore(':').toInt() }.distinct(), "tuneSupported" to (boundCamera != null), "probeSupported" to modelAvailable, "message" to detail)
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
                val previewBuilder = Preview.Builder().setTargetRotation(rotation)
                Camera2Interop.Extender(previewBuilder).setSessionCaptureCallback(object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                        if (generation != token) return
                        af = result.get(CaptureResult.CONTROL_AF_STATE)
                        ae = result.get(CaptureResult.CONTROL_AE_STATE)
                        if (tuned && !locked) tuned = false
                    }
                })
                val preview = previewBuilder.build().also { useCase ->
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
                analysis.setAnalyzer(analysisWorker) { proxy ->
                    try {
                        val now = System.currentTimeMillis()
                        if (generation == token) {
                            if (modelAvailable && now - (latest?.timestamp ?: 0L) >= 100) {
                                val frame = runCatching { LumaFrame.from(proxy, now) }.getOrNull()
                                if (generation == token) latest = frame
                            }
                            frameMs = SystemClock.elapsedRealtime()
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
            FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE).disableAutoCancel().build()
        }
        try {
            if (tuning) { result.error("busy", "相机正在调优", null); return }
            tuned = false
            val info = Camera2CameraInfo.from(camera.cameraInfo)
            if (info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) != true) {
                detail = "相机不支持 AE 锁定"; result.success(report()); return
            }
            val action = make()
            if (!camera.cameraInfo.isFocusMeteringSupported(action)) {
                detail = "该相机不支持 ROI 点调焦/测光，真实采集仍禁用"
                result.success(report()); return
            }
            val token = generation
            val attempt = ++tuneGeneration
            val control = Camera2CameraControl.from(camera.cameraControl)
            val executor = ContextCompat.getMainExecutor(this)
            fun setAeLock(value: Boolean) = control.addCaptureRequestOptions(
                CaptureRequestOptions.Builder().setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, value).build())
            tuning = true
            val end = SystemClock.elapsedRealtime() + ((roi["timeoutMs"] as? Number)?.toLong() ?: 2000).coerceIn(1000, 5000)
            fun finish(success: Boolean, message: String) {
                if (token == generation && attempt == tuneGeneration) {
                    tuning = false
                    tuned = success
                    detail = message
                    if (!success) { setAeLock(false); camera.cameraControl.cancelFocusAndMetering() }
                }
                result.success(report())
            }
            var focusResult: androidx.camera.core.FocusMeteringResult? = null
            var focusFinished = false
            var lockRequested = false
            val verify = object : Runnable {
                override fun run() {
                    if (token != generation || attempt != tuneGeneration) { result.error("camera_lost", "相机会话已改变", null); return }
                    if (lockRequested && af == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED && ae == CaptureResult.CONTROL_AE_STATE_LOCKED) {
                        finish(true, "AF/AE 已确认锁定"); return
                    }
                    if (SystemClock.elapsedRealtime() >= end || (focusFinished && focusResult?.isFocusSuccessful != true)) {
                        finish(false, "AF/AE 未确认锁定，请重试"); return
                    }
                    if (!lockRequested && focusResult?.isFocusSuccessful == true &&
                        af == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED && ae == CaptureResult.CONTROL_AE_STATE_CONVERGED) {
                        lockRequested = true
                        setAeLock(true)
                    }
                    handler.postDelayed(this, 40)
                }
            }
            val unlock = setAeLock(false)
            unlock.addListener({
                if (token == generation && attempt == tuneGeneration && tuning) {
                    runCatching { unlock.get() }.onSuccess {
                        val focus = camera.cameraControl.startFocusAndMetering(action)
                        focus.addListener({ focusResult = runCatching { focus.get() }.getOrNull(); focusFinished = true }, executor)
                    }.onFailure { focusFinished = true }
                }
            }, executor)
            handler.post(verify)
        } catch (e: Exception) { tuning = false; result.error("tune_failed", e.message, null) }
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int = windowManager.defaultDisplay.rotation

    private fun sample(args: Map<*, *>?, result: MethodChannel.Result) {
        val token = generation
        val frame = latest
        if (args?.get("sessionId") != token || !freshFrame() || frame == null) {
            result.error("camera_lost", "相机会话或帧已失效", null); return
        }
        if (!locked) { result.error("lock_lost", "AF/AE 锁定已失效", null); return }
        if (!storageReady()) { result.error("storage_low", "本地存储空间不足", null); return }
        val rec = if (modelAvailable) model else null
        if (rec == null) { result.error("model_lost", modelProblem ?: "REC 未加载", null); return }
        val rois = (args["rois"] as? List<*>)?.map { it as? Map<*, *> }
        val budget = (args["budgetMs"] as? Number)?.toLong() ?: 0
        if (rois == null || rois.size !in 1..8 || rois.any { it?.get("deviceId") !is String } || budget !in 1..4000) {
            result.error("invalid_sample", "ROI 或采样预算无效", null); return
        }
        if (probeRunning) { result.error("busy", "REC 正在运行", null); return }
        val snapshot = args["saveSnapshot"] == true
        val low = (args["low"] as? Number)?.toDouble() ?: .60
        probeRunning = true
        val deadline = SystemClock.elapsedRealtime() + budget
        worker.execute {
            val readings = mutableListOf<Map<String, Any>>()
            for (roi in rois) {
                if (generation != token || SystemClock.elapsedRealtime() >= deadline) break
                val region = requireNotNull(roi)
                val reading = rec.recognize(frame, region)
                val value = (reading["text"] as String).toDoubleOrNull()
                val failed = reading["error"] != null || value == null || !value.isFinite() || (reading["confidence"] as Number).toDouble() < low
                readings.add(if (snapshot && failed) reading + (frame.snapshot(region)?.let { mapOf("snapshot" to it) } ?: emptyMap()) else reading)
            }
            runOnUiThread {
                probeRunning = false
                when {
                    generation != token || !freshFrame() -> result.error("camera_lost", "相机会话已失效", null)
                    !locked -> result.error("lock_lost", "采样期间 AF/AE 锁定失效", null)
                    readings.size != rois.size || SystemClock.elapsedRealtime() >= deadline -> result.error("sample_timeout", "识别超时", null)
                    else -> result.success(mapOf("timestampMs" to frame.timestamp, "readings" to readings))
                }
            }
        }
    }

    private fun closeCamera(resetDetail: Boolean = true) {
        generation++
        tuneGeneration++
        tuned = false
        tuning = false
        af = null
        ae = null
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
        analysisWorker.shutdown()
        worker.shutdown()
        super.onDestroy()
    }
}
