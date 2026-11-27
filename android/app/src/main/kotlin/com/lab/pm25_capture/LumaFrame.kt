package com.lab.pm25_capture

import androidx.camera.core.ImageProxy
import kotlin.math.floor
import kotlin.math.roundToInt

// Inverse of Flutter's clockwise RotatedBox / rotateRoi transformation.
internal fun inverseX(turns: Int,u: Double,v: Double) = when (turns) {1->v;2->1-u;3->1-v;else->u}
internal fun inverseY(turns: Int,u: Double,v: Double) = when (turns) {1->1-u;2->1-v;3->u;else->v}

/** Immutable, cropped YUV data in sensor order; every consumer uses the same inverse rotation. */
internal class LumaFrame(
    private val yPlane: ByteArray, private val uPlane: ByteArray, private val vPlane: ByteArray,
    private val width: Int, private val height: Int, private val rotation: Int, val timestamp: Long,
    private val left: Int, private val top: Int, private val sourceWidth: Int, private val sourceHeight: Int
) {
    private val chromaWidth = (left % 2 + width + 1) / 2
    val uprightWidth get() = if (rotation % 180 == 0) width else height
    val uprightHeight get() = if (rotation % 180 == 0) height else width
    private fun rawX(u: Double,v: Double) = inverseX(rotation/90,u,v)
    private fun rawY(u: Double,v: Double) = inverseY(rotation/90,u,v)
    fun fullFrameX(u: Double,v: Double) = (left + rawX(u,v)*width) / sourceWidth
    fun fullFrameY(u: Double,v: Double) = (top + rawY(u,v)*height) / sourceHeight
    private fun x(u: Double,v: Double) = (rawX(u,v)*width).toInt().coerceIn(0,width-1)
    private fun y(u: Double,v: Double) = (rawY(u,v)*height).toInt().coerceIn(0,height-1)
    private fun grayAt(x: Int,y: Int) = yPlane[y*width+x].toInt() and 255
    fun colorAt(u: Double,v: Double) = rgb(x(u,v),y(u,v))
    private fun rgb(x: Int,y: Int): Int {
        val i = (left % 2 + x)/2 + ((top % 2 + y)/2)*chromaWidth
        val yy = (grayAt(x,y) - 16).coerceAtLeast(0)
        val u = (uPlane[i].toInt() and 255)-128
        val v = (vPlane[i].toInt() and 255)-128
        val r = ((298*yy+409*v+128) shr 8).coerceIn(0,255)
        val g = ((298*yy-100*u-208*v+128) shr 8).coerceIn(0,255)
        val b = ((298*yy+516*u+128) shr 8).coerceIn(0,255)
        return (255 shl 24) or (r shl 16) or (g shl 8) or b
    }
    fun interpolatedColor(u: Double, v: Double): Int {
        val x = (rawX(u,v)*width-.5).coerceIn(0.0,width-1.0)
        val y = (rawY(u,v)*height-.5).coerceIn(0.0,height-1.0)
        val ix = floor(x).toInt(); val iy = floor(y).toInt()
        val fx = x-ix; val fy = y-iy
        val nx = (ix+1).coerceAtMost(width-1); val ny = (iy+1).coerceAtMost(height-1)
        val tl = rgb(ix,iy); val tr = rgb(nx,iy); val bl = rgb(ix,ny); val br = rgb(nx,ny)
        fun channel(shift: Int): Int {
            val a = ((tl shr shift) and 255)*(1-fx)+((tr shr shift) and 255)*fx
            val b = ((bl shr shift) and 255)*(1-fx)+((br shr shift) and 255)*fx
            return (a*(1-fy)+b*fy).roundToInt()
        }
        return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }
    fun snapshot(roi: Map<*, *>, displayTurns: Int): ByteArray? = runCatching {
        val l = (roi["l"] as Number).toDouble(); val r = (roi["r"] as Number).toDouble()
        val t = (roi["t"] as Number).toDouble(); val b = (roi["b"] as Number).toDouble()
        require(l >= 0 && t >= 0 && r <= 1 && b <= 1 && r > l && b > t)
        val w = 96; val h = 32
        val header = "P5\n$w $h\n255\n".toByteArray(Charsets.US_ASCII)
        header + ByteArray(w*h) { i ->
            val px=(i%w+.5)/w; val py=(i/w+.5)/h
            val u=l+(r-l)*inverseX(displayTurns,px,py); val v=t+(b-t)*inverseY(displayTurns,px,py)
            grayAt(x(u,v),y(u,v)).toByte()
        }
    }.getOrNull()
    companion object {
        private fun copy(p: ImageProxy.PlaneProxy, l: Int,t: Int,w: Int,h: Int): ByteArray {
            val buffer = p.buffer.duplicate(); val origin = buffer.position(); val out = ByteArray(w*h)
            for (y in 0 until h) {
                val start = origin+(y+t)*p.rowStride+l*p.pixelStride
                if (p.pixelStride == 1) { buffer.position(start); buffer.get(out,y*w,w) }
                else for (x in 0 until w) out[y*w+x] = buffer.get(start+x*p.pixelStride)
            }
            return out
        }
        fun from(proxy: ImageProxy,timestamp: Long): LumaFrame {
            val crop=proxy.cropRect; val w=crop.width(); val h=crop.height(); val l=crop.left; val t=crop.top
            require(w>0 && h>0)
            val cw=(l%2+w+1)/2; val ch=(t%2+h+1)/2
            return LumaFrame(copy(proxy.planes[0],l,t,w,h),copy(proxy.planes[1],l/2,t/2,cw,ch),
                copy(proxy.planes[2],l/2,t/2,cw,ch),w,h,proxy.imageInfo.rotationDegrees,timestamp,l,t,proxy.width,proxy.height)
        }
    }
}
