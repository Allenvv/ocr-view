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
import android.util.Log
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
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
    private val analysisWorker = Executors.newSingleThreadExecutor { task ->
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            task.run()
        }, "pm25-preview")
    }
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
        val cameraId = activeLens?.key ?: return emptyMap()
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
    @Volatile private var previewFps = 0.0
    private var fixed30Requested = false
    @Volatile private var fixed30Reported = false
    private var lenses = listOf<OpticalLens>()
    private val unavailableLenses = mutableSetOf<String>()
    private var activeLens: OpticalLens? = null
    private var adjustingCamera = false
    private var captureFrozen = false
    @Volatile private var antiBanding: Int? = null
    private var raster: PreviewRaster? = null
    private var analysisUseCase: ImageAnalysis? = null
    private var detail = "尚未打开后置相机"
    @Volatile private var generation = 0
    @Volatile private var latest: LumaFrame? = null
    @Volatile private var modelLoading = false
    @Volatile private var modelProblem: String? = null
    @Volatile private var model: RecModel? = null
    private val modelAvailable get() = model != null
    private var probeRunning = false

    // The home screen and historical records do not need to initialize native OCR.
    private fun loadModelForCapture() {
        if (modelLoading || modelAvailable) return
        modelProblem = null
        modelLoading = true
        worker.execute {
            try {
                model = RecModel(assets)
            } catch (e: Exception) {
                reportModelLoadFailure(e)
            } catch (e: LinkageError) {
                reportModelLoadFailure(e)
            } finally {
                modelLoading = false
            }
        }
    }

    private fun reportModelLoadFailure(error: Throwable) {
        Log.e("PM25-REC", "Bundled offline model initialization failed", error)
        modelProblem = "${error.javaClass.simpleName}：${error.message ?: "初始化失败"}"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                "switchLens" -> {
                    val key = call.argument<String>("id")
                    val lens = lenses.firstOrNull { it.key == key && key !in unavailableLenses }
                    when {
                        pending != null || tuning || adjustingCamera || captureFrozen -> result.error("busy", "采集或调整期间不能切换镜头", null)
                        lens == null || boundCamera == null -> result.error("lens_unavailable", "该光学镜头不可用", null)
                        activeLens?.key == key -> result.success(report())
                        else -> {
                            val previous = activeLens
                            closeCamera()
                            pending = result
                            openCamera(flutterEngine.renderer, lens, previous)
                        }
                    }
                }
                "focusAt" -> adjustCamera(call.arguments as? Map<*, *>, false, result)
                "exposure" -> adjustCamera(call.arguments as? Map<*, *>, true, result)
                "tune" -> tune(call.arguments as? Map<*, *>, result)
                "probe" -> {
                    val roi = call.arguments as? Map<*,*>
                    val frame = latest
                    if (!modelAvailable || roi == null || frame == null || System.currentTimeMillis()-frame.timestamp > 1500)
                        result.error("probe_unavailable", modelProblem ?: "没有可供识别的新鲜帧或模型", null)
                    else if (probeRunning) result.error("busy", "识别测试运行中", null)
                    else {
                        probeRunning = true
                        val turns = currentDisplayTurns()
                        worker.execute {
                            val reading = model?.recognize(frame, roi, turns)
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
        val cameraInfo = boundCamera?.cameraInfo
        val turns = currentDisplayTurns()
        val frame = latest
        val canonicalWidth = frame?.uprightWidth ?: 9
        val canonicalHeight = frame?.uprightHeight ?: 16
        val swap = turns % 2 != 0
        val exchange = frame != null && ((frame.rotation / 90 + turns) % 2 != 0)
        val exposure = boundCamera?.cameraInfo?.exposureState
        return mapOf("textureId" to if (frame != null) texture?.id() else null,
            "width" to if (swap) canonicalHeight else canonicalWidth, "height" to if (swap) canonicalWidth else canonicalHeight,
            "turns" to turns, "bufferTurns" to 0, "viewportVersion" to 2,
            "analysisOutputWidth" to frame?.let { if (exchange) it.sourceHeight else it.sourceWidth },
            "analysisOutputHeight" to frame?.let { if (exchange) it.sourceWidth else it.sourceHeight },
            "previewWidth" to frame?.let { if (swap) canonicalHeight else canonicalWidth },
            "previewHeight" to frame?.let { if (swap) canonicalWidth else canonicalHeight },
            "previewFps" to previewFps, "antiBanding" to antiBanding,
            "fixed30Requested" to fixed30Requested, "fixed30Reported" to fixed30Reported,
            "lensId" to activeLens?.key,
            "lenses" to lenses.filterNot { it.key in unavailableLenses }.map { mapOf("id" to it.key, "mm" to it.equivalent) },
            "adjustSupported" to (boundCamera != null && freshFrame()),
            "aeLockSupported" to (cameraInfo?.let { Camera2CameraInfo.from(it).getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) } == true),
            "exposureMin" to exposure?.takeIf { it.isExposureCompensationSupported }?.exposureCompensationRange?.lower,
            "exposureMax" to exposure?.takeIf { it.isExposureCompensationSupported }?.exposureCompensationRange?.upper,
            "exposureIndex" to exposure?.exposureCompensationIndex,
            "exposureStep" to exposure?.exposureCompensationStep?.toDouble(),
            "modelAvailable" to modelAvailable, "modelLoading" to modelLoading, "modelProblem" to modelProblem,
            "modelVersion" to model?.version, "modelSha256" to model?.sha256, "dictionarySha256" to model?.dictionarySha256, "runtimeVersion" to "1.22.0",
            "sessionId" to generation, "afState" to af, "aeState" to ae, "locked" to locked,
            "cameraId" to activeLens?.key,
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

    private fun openCamera(registry: TextureRegistry, lens: OpticalLens? = null, rollback: OpticalLens? = null, warning: String? = null) {
        loadModelForCapture()
        val token = ++generation
        val future = ProcessCameraProvider.getInstance(this)
        val main = ContextCompat.getMainExecutor(this)
        future.addListener({
            if (generation != token || pending == null) return@addListener
            try {
                val cameras = future.get().also { provider = it }
                val default = CameraSelector.DEFAULT_BACK_CAMERA
                require(cameras.hasCamera(default)) { "未找到后置相机" }
                val defaultId = Camera2CameraInfo.from(cameras.getCameraInfo(default)).cameraId
                if (lens == null) lenses = rearLenses(this, cameras, defaultId)
                val target = lens ?: requireNotNull(lenses.firstOrNull { it.key == defaultId })
                val selector = if (lens == null) default else target.selector()
                activeLens = target
                // A single analysis image owns RGB preview, OCR and metering coordinates.
                val entry = registry.createSurfaceTexture().also { texture = it }
                val renderer = PreviewRaster(entry).also { raster = it }
                val display = displayRotation()
                val sideways = display == Surface.ROTATION_90 || display == Surface.ROTATION_270
                val naturalLandscape = (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) != sideways
                val ratio = if (naturalLandscape) Rational(16, 9) else Rational(9, 16)
                val rotation = Surface.ROTATION_0
                val cameraInfo = cameras.getCameraInfo(selector)
                val resolution = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(ResolutionStrategy(Size(1920, 1080), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                    .build()
                val builder = ImageAnalysis.Builder().setResolutionSelector(resolution).setTargetRotation(rotation)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                val interop = Camera2Interop.Extender(builder)
                val controls = Camera2CameraInfo.from(cameraInfo)
                if (target.physical != null && android.os.Build.VERSION.SDK_INT >= 28) {
                    interop.setPhysicalCameraId(target.physical)
                }
                val fixed30 = android.util.Range(30, 30)
                val streamCharacteristics = if (target.physical == null) null else
                    (getSystemService(CAMERA_SERVICE) as android.hardware.camera2.CameraManager).getCameraCharacteristics(target.physical)
                val modes = streamCharacteristics?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                    ?: controls.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                fixed30Requested = modes?.contains(fixed30) == true
                if (fixed30Requested) interop.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fixed30)
                val physicalConfirmed = java.util.concurrent.atomic.AtomicBoolean(target.physical == null)
                if (controls.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_ANTIBANDING_MODES)
                        ?.contains(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_AUTO) == true) {
                    interop.setCaptureRequestOption(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_AUTO)
                }
                interop.setSessionCaptureCallback(object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                        if (generation != token) return
                        @Suppress("DEPRECATION")
                        val metadata = if (target.physical != null && android.os.Build.VERSION.SDK_INT >= 28) {
                            (result.physicalCameraResults[target.physical] ?: return).also { physicalConfirmed.set(true) }
                        } else result
                        fixed30Reported = request.get(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE) == fixed30
                        antiBanding = metadata.get(CaptureResult.CONTROL_AE_ANTIBANDING_MODE)
                        af = metadata.get(CaptureResult.CONTROL_AF_STATE)
                        ae = metadata.get(CaptureResult.CONTROL_AE_STATE)
                        if (tuned && !locked) tuned = false
                    }
                })
                val analysis = builder.build().also { analysisUseCase = it }
                var fpsStart = 0L
                var painted = 0
                var previewFailed = false
                var firstFrame = true
                analysis.setAnalyzer(analysisWorker) { proxy ->
                    try {
                        val now = SystemClock.elapsedRealtime()
                        if (generation == token && !previewFailed && physicalConfirmed.get()) {
                            val frame = LumaFrame.from(proxy, System.currentTimeMillis())
                            renderer.draw(frame)
                            if (generation == token) {
                                latest = frame
                                val done = SystemClock.elapsedRealtime()
                                frameMs = done
                                if (fpsStart == 0L) fpsStart = done
                                else {
                                    painted++
                                    if (done - fpsStart >= 1000L) {
                                        previewFps = painted * 1000.0 / (done - fpsStart)
                                        painted = 0
                                        fpsStart = done
                                    }
                                }
                                if (firstFrame) {
                                    firstFrame = false
                                    if (rollback != null) main.execute {
                                        if (generation == token) finishOpen()
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        previewFailed = true
                        if (generation == token) main.execute {
                            if (generation == token) detail = "相机画面处理失败：${e.message}"
                        }
                    } finally { proxy.close() }
                }
                val viewPort = ViewPort.Builder(ratio, rotation).setScaleType(ViewPort.FILL_CENTER).build()
                val group = UseCaseGroup.Builder().setViewPort(viewPort).addUseCase(analysis).build()
                val camera = cameras.bindToLifecycle(this,selector,group)
                boundCamera = camera
                camera.cameraInfo.cameraState.observe(this) { state ->
                    if (generation == token && state.error != null) detail = "CameraX 相机错误：${state.error?.code}"
                    else if (generation == token && state.type == CameraState.Type.OPEN) detail = "后置相机已连接"
                }
                detail = warning ?: "后置相机已连接"
                if (rollback == null) finishOpen()
                else handler.postDelayed({
                    if (generation == token && pending != null) {
                        unavailableLenses.add(target.key)
                        val reply = pending
                        pending = null
                        closeCamera()
                        pending = reply
                        openCamera(registry, rollback, warning = "新镜头没有可确认的画面，已返回原镜头")
                    }
                }, 4500)
            } catch (e: Exception) {
                detail = "相机启动失败：${e.message}"
                if (rollback != null && lens != null) {
                    unavailableLenses.add(lens.key)
                    val reply = pending
                    pending = null
                    closeCamera()
                    pending = reply
                    openCamera(registry, rollback, warning = "无法使用新镜头，已返回原镜头")
                } else closeCamera(resetDetail = false)
            }
        },main)
    }

    @Suppress("DEPRECATION")
    private fun meteringAction(u: Double, v: Double, hold: Boolean): FocusMeteringAction {
        require(u in 0.0..1.0 && v in 0.0..1.0) { "对焦点越界" }
        val frame = requireNotNull(latest) { "相机还没有可用图像" }
        val point = SurfaceOrientedMeteringPointFactory(1f, 1f, requireNotNull(analysisUseCase))
            .createPoint(frame.fullFrameX(u, v).toFloat(), frame.fullFrameY(u, v).toFloat())
        return FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .apply { if (hold) disableAutoCancel() }.build()
    }

    private fun adjustCamera(args: Map<*, *>?, exposureOnly: Boolean, result: MethodChannel.Result) {
        val camera = boundCamera
        if (camera == null || !freshFrame()) { result.error("not_ready", "相机未就绪", null); return }
        if (captureFrozen || tuning) { result.error("busy", "采集或锁定期间不能调整相机", null); return }
        if (adjustingCamera) { result.error("busy", "相机正在调整，请稍候", null); return }
        val token = generation
        val executor = ContextCompat.getMainExecutor(this)
        fun finish(message: String?) {
            if (token != generation) { result.error("camera_lost", "相机会话已改变", null); return }
            adjustingCamera = false
            if (message == null) result.success(report()) else result.error("camera_adjustment", message, null)
        }
        try {
            val index = if (exposureOnly) (args?.get("index") as? Int) else null
            val action = if (exposureOnly) null else meteringAction(
                (args?.get("u") as Number).toDouble(), (args["v"] as Number).toDouble(), false)
            if (exposureOnly) {
                val state = camera.cameraInfo.exposureState
                require(state.isExposureCompensationSupported) { "此相机不支持曝光补偿" }
                require(index != null && state.exposureCompensationRange.contains(index)) { "曝光档位越界" }
            } else require(camera.cameraInfo.isFocusMeteringSupported(requireNotNull(action))) { "此相机不支持点按对焦" }
            val wasTuned = tuned
            tuned = false
            adjustingCamera = true
            val apply = {
                if (token != generation) finish("相机会话已改变")
                else if (exposureOnly) {
                    val future = camera.cameraControl.setExposureCompensationIndex(requireNotNull(index))
                    future.addListener({ finish(runCatching { future.get() }.exceptionOrNull()?.let { "曝光补偿未生效：${it.cause?.message ?: it.message}" }) }, executor)
                } else {
                    val future = camera.cameraControl.startFocusAndMetering(requireNotNull(action))
                    future.addListener({
                        finish(if (runCatching { future.get().isFocusSuccessful }.getOrDefault(false)) null else "未确认对焦，请对准仪器后重试")
                    }, executor)
                }
            }
            if (wasTuned) {
                val future = Camera2CameraControl.from(camera.cameraControl).addCaptureRequestOptions(
                    CaptureRequestOptions.Builder().setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, false).build())
                future.addListener({ if (runCatching { future.get() }.isSuccess) apply() else finish("无法解除曝光锁定") }, executor)
            } else apply()
        } catch (e: Exception) { finish(e.message ?: "相机调整失败") }
    }

    private fun tune(roi: Map<*, *>?, result: MethodChannel.Result) {
        val camera = boundCamera
        if (camera == null || roi == null) { result.error("not_ready", "相机未就绪", null); return }
        try {
            if (tuning || adjustingCamera || captureFrozen) { result.error("busy", "相机正在调整或采集中", null); return }
            tuned = false
            val info = Camera2CameraInfo.from(camera.cameraInfo)
            if (info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) != true) {
                detail = "相机不支持 AE 锁定"; result.success(report()); return
            }
            val action = meteringAction(
                ((roi["l"] as Number).toDouble() + (roi["r"] as Number).toDouble()) / 2,
                ((roi["t"] as Number).toDouble() + (roi["b"] as Number).toDouble()) / 2, true)
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

    private fun currentDisplayTurns(): Int {
        val cameraInfo = boundCamera?.cameraInfo ?: return 0
        return Math.floorMod(cameraInfo.getSensorRotationDegrees(displayRotation()) -
            cameraInfo.getSensorRotationDegrees(Surface.ROTATION_0), 360) / 90
    }

    private fun sample(args: Map<*, *>?, result: MethodChannel.Result) {
        val token = generation
        val frame = latest
        if (args?.get("sessionId") != token || !freshFrame() || frame == null) {
            result.error("camera_lost", "相机会话或帧已失效", null); return
        }
        if (!locked) { result.error("lock_lost", "AF/AE 锁定已失效", null); return }
        captureFrozen = true
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
        val turns = currentDisplayTurns()
        worker.execute {
            val readings = mutableListOf<Map<String, Any>>()
            for (roi in rois) {
                if (generation != token || SystemClock.elapsedRealtime() >= deadline) break
                val region = requireNotNull(roi)
                val reading = rec.recognize(frame, region, turns)
                val value = (reading["text"] as String).toDoubleOrNull()
                val failed = reading["error"] != null || value == null || !value.isFinite() || (reading["confidence"] as Number).toDouble() < low
                readings.add(if (snapshot && failed) reading + (frame.snapshot(region, turns)?.let { mapOf("snapshot" to it) } ?: emptyMap()) else reading)
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
        adjustingCamera = false
        captureFrozen = false
        previewFps = 0.0
        fixed30Requested = false
        fixed30Reported = false
        activeLens = null
        antiBanding = null
        af = null
        ae = null
        provider?.unbindAll()
        boundCamera = null
        val oldRaster = raster
        raster = null
        // Abandon the consumer before queueing cleanup so a producer waiting
        // in eglSwapBuffers can return even after Flutter stops painting it.
        texture?.release()
        texture = null
        if (oldRaster != null) analysisWorker.execute { oldRaster.close() }
        analysisUseCase = null
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
