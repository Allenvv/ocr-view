package com.lab.pm25_capture

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics as CC
import android.hardware.camera2.CameraManager
import android.os.Build
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import kotlin.math.abs

internal data class OpticalLens(val host: String, val physical: String?, val equivalent: Float) {
    val key: String get() = if (physical == null) host else "$host/$physical"
}

@ExperimentalCamera2Interop
internal fun rearLenses(context: Context, provider: ProcessCameraProvider, defaultId: String): List<OpticalLens> {
    val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    val cameras = provider.availableCameraInfos.map { Camera2CameraInfo.from(it).cameraId }.toSet()
    fun characteristics(id: String) = runCatching { manager.getCameraCharacteristics(id) }.getOrNull()
    fun equivalent(c: CC?): Float? {
        if (c?.get(CC.LENS_FACING) != CC.LENS_FACING_BACK ||
            c.get(CC.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(ImageFormat.YUV_420_888).isNullOrEmpty()) return null
        val focal = c.get(CC.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return null
        val size = c.get(CC.SENSOR_INFO_PHYSICAL_SIZE) ?: return null
        return (36f * focal / maxOf(size.width, size.height)).takeIf { it.isFinite() && it > 0 }
    }
    val standard = equivalent(characteristics(defaultId)) ?: return listOf(OpticalLens(defaultId, null, 0f))
    val result = mutableListOf(OpticalLens(defaultId, null, standard))
    fun add(lens: OpticalLens) {
        if (result.none { abs(it.equivalent / lens.equivalent - 1f) < .1f }) result.add(lens)
    }
    for (id in cameras.sorted()) {
        val c = characteristics(id) ?: continue
        val physical = if (Build.VERSION.SDK_INT >= 28) c.physicalCameraIds else emptySet()
        if (id != defaultId && physical.isEmpty()) equivalent(c)?.let { add(OpticalLens(id, null, it)) }
        if (Build.VERSION.SDK_INT >= 28) for (pid in physical.sorted()) {
            val sensor = characteristics(pid) ?: continue
            if (sensor.get(CC.SENSOR_ORIENTATION) != c.get(CC.SENSOR_ORIENTATION)) continue
            equivalent(sensor)?.let { add(OpticalLens(id, pid, it)) }
        }
    }
    return result.sortedBy { it.equivalent }
}

@ExperimentalCamera2Interop
internal fun OpticalLens.selector() = CameraSelector.Builder().requireLensFacing(CameraSelector.LENS_FACING_BACK)
    .addCameraFilter { infos -> infos.filter { Camera2CameraInfo.from(it).cameraId == host } }.build()
