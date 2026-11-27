package com.lab.pm25_capture

import android.graphics.Bitmap
import android.graphics.Rect
import android.view.Surface
import io.flutter.view.TextureRegistry
import kotlin.math.min
import kotlin.math.roundToInt

/** Paints an already upright ROI viewport. The camera never owns this surface,
 * so the HAL/Flutter texture backend cannot add an implicit sensor rotation. */
internal class PreviewRaster(private val entry: TextureRegistry.SurfaceTextureEntry) : AutoCloseable {
    private val surface = Surface(entry.surfaceTexture())
    private var closed = false
    private var bitmap: Bitmap? = null
    private var pixels = IntArray(0)

    @Synchronized fun draw(frame: LumaFrame) {
        if (closed) return
        val scale = min(1.0, 640.0 / maxOf(frame.uprightWidth, frame.uprightHeight))
        val width = (frame.uprightWidth * scale).roundToInt().coerceAtLeast(1)
        val height = (frame.uprightHeight * scale).roundToInt().coerceAtLeast(1)
        val target = bitmap?.takeIf { it.width == width && it.height == height } ?: run {
            bitmap?.recycle()
            entry.surfaceTexture().setDefaultBufferSize(width, height)
            pixels = IntArray(width * height)
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmap = it }
        }
        for (y in 0 until height) {
            val v = (y + .5) / height
            for (x in 0 until width) pixels[y * width + x] = frame.colorAt((x + .5) / width, v)
        }
        target.setPixels(pixels, 0, width, 0, 0, width, height)
        val canvas = surface.lockCanvas(null)
        try {
            canvas.drawBitmap(target, null, Rect(0, 0, canvas.width, canvas.height), null)
        } finally { surface.unlockCanvasAndPost(canvas) }
    }

    @Synchronized override fun close() {
        closed = true
        bitmap?.recycle()
        bitmap = null
        surface.release()
    }
}
