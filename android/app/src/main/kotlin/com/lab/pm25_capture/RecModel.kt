package com.lab.pm25_capture

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.res.AssetManager
import androidx.camera.core.ImageProxy
import org.json.JSONObject
import java.nio.FloatBuffer
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.roundToInt

/** Local REC-only PoC. Model files are supplied by the project, not downloaded at runtime. */
internal class RecModel(assets: AssetManager) : AutoCloseable {
    companion object { private const val DICTIONARY = "0123456789." }
    private val config = JSONObject(assets.open("rec.json").bufferedReader().use { it.readText() })
    private val w = config.getInt("width").also { require(it in 8..1024) }
    private val h = config.getInt("height").also { require(it in 8..256) }
    private val mean = config.optDouble("mean", .5).also { require(it.isFinite()) }
    private val scale = config.optDouble("scale", .5).also { require(it.isFinite() && it > 0) }
    private val environment = OrtEnvironment.getEnvironment()
    private val session = OrtSession.SessionOptions().use { options ->
        options.setIntraOpNumThreads(1)
        environment.createSession(assets.open("rec.onnx").use { it.readBytes() }, options)
    }
    private val input = session.inputNames.single()
    private val tensor = FloatArray(w*h)
    fun recognize(frame: LumaFrame, roi: Map<*,*>): Map<String,Any> {
        val id = roi["deviceId"] as String
        return try {
            val l=(roi["l"] as Number).toDouble(); val r=(roi["r"] as Number).toDouble()
            val t=(roi["t"] as Number).toDouble(); val b=(roi["b"] as Number).toDouble()
            require(listOf(l,t,r,b).all { it.isFinite() && it in 0.0..1.0 } && r>l && b>t)
            for (y in 0 until h) for (x in 0 until w) {
                val u=l+(r-l)*(x+.5)/w; val v=t+(b-t)*(y+.5)/h
                tensor[y*w+x]=((frame.at(u,v)/255.0-mean)/scale).toFloat()
            }
            OnnxTensor.createTensor(environment, FloatBuffer.wrap(tensor),longArrayOf(1,1,h.toLong(),w.toLong())).use { inputTensor ->
                session.run(mapOf(input to inputTensor)).use { result ->
                    val logits=(result[0].value as Array<*>).single() as Array<*>
                    var previous=0; var sum=0.0; var count=0
                    val text=StringBuilder()
                    for (step in logits) {
                        val values=step as FloatArray
                        require(values.size==12 && values.all { it.isFinite() }) { "REC output must be [1,T,12] logits" }
                        val idx=values.indices.maxBy { values[it] }
                        if (idx!=0 && idx!=previous) {
                            text.append(DICTIONARY[idx-1]); count++
                            sum += 1.0 / values.sumOf { exp((it-values[idx]).toDouble()) }
                        }
                        previous=idx
                    }
                    mapOf("deviceId" to id,"text" to text.toString(),"confidence" to if(count==0) 0.0 else sum/count)
                }
            }
        } catch (e:Exception) { mapOf("deviceId" to id,"text" to "","confidence" to 0.0,"error" to (e.message?:"REC 失败")) }
    }
    override fun close() = session.close()
}

internal class LumaFrame(val bytes:ByteArray,val width:Int,val height:Int,val rotation:Int,val timestamp:Long) {
    fun at(u:Double,v:Double):Int {
        val (x,y)=when(rotation){90->v to 1-u;180->1-u to 1-v;270->1-v to u;else->u to v}
        return bytes[floor(y*height).roundToInt().coerceIn(0,height-1)*width+floor(x*width).roundToInt().coerceIn(0,width-1)].toInt() and 255
    }
    companion object {
        fun from(proxy:ImageProxy,timestamp:Long):LumaFrame {
            val rect=proxy.cropRect;val w=rect.width();val h=rect.height();val plane=proxy.planes[0];val data=plane.buffer.duplicate()
            val out=ByteArray(w*h);val base=data.position()
            for(y in 0 until h){
                val start=base+(y+rect.top)*plane.rowStride+rect.left*plane.pixelStride
                if(plane.pixelStride==1){data.position(start);data.get(out,y*w,w)}
                else for(x in 0 until w){out[y*w+x]=data.get(start+x*plane.pixelStride)}
            }
            return LumaFrame(out,w,h,proxy.imageInfo.rotationDegrees,timestamp)
        }
    }
}
