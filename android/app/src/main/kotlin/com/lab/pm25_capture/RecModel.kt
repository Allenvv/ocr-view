package com.lab.pm25_capture

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.content.res.AssetManager
import org.json.JSONArray
import org.json.JSONObject
import java.nio.FloatBuffer
import java.security.MessageDigest
import kotlin.math.ceil

/** Offline, recognition-only PaddleOCR export; no detection or network calls. */
internal class RecModel(private val assets: AssetManager) : AutoCloseable {
    private val config = JSONObject(assets.open("rec.json").bufferedReader().use { it.readText() })
    val version = config.getString("version").also { require(it.isNotBlank()) }
    val sha256 = config.getString("sha256")
    val dictionarySha256 = config.getString("dictionarySha256")
    private fun checked(name: String, hash: String): ByteArray = assets.open(name).use { it.readBytes() }.also {
        val actual = MessageDigest.getInstance("SHA-256").digest(it).joinToString("") { byte -> "%02x".format(byte) }
        require(actual == hash) { "$name SHA-256 校验失败" }
    }
    private val dictionary = JSONArray(String(checked("rec.dict.json", dictionarySha256), Charsets.UTF_8))
    private val w = config.getInt("width").also { require(it == 320) }
    private val h = config.getInt("height").also { require(it == 48) }
    private val mean = config.getDouble("mean").also { require(it == .5) }
    private val scale = config.getDouble("scale").also { require(it == .5) }
    private val classes = config.getInt("classCount").also { require(it == dictionary.length()+1) }
    private val environment = OrtEnvironment.getEnvironment()
    private val session = OrtSession.SessionOptions().use { options ->
        require(config.getString("decoder") == "ctc-probabilities" && config.getInt("blankIndex") == 0 &&
            config.getInt("channels") == 3 && config.getString("input") == "BGR" &&
            config.getString("resize") == "aspect-right-pad")
        checked("rec-upstream.yml", config.getString("upstreamConfigSha256"))
        options.setIntraOpNumThreads(1)
        environment.createSession(checked("rec.onnx", sha256), options)
    }
    private val input = try {
        val inInfo = session.inputInfo.values.single().info as TensorInfo
        val outInfo = session.outputInfo.values.single().info as TensorInfo
        val dims = inInfo.shape
        require(inInfo.type == OnnxJavaType.FLOAT && dims.size == 4 && (dims[0] == 1L || dims[0] < 0) &&
            dims[1] == 3L && dims[2] == h.toLong() && (dims[3] == w.toLong() || dims[3] < 0)) { "REC 输入契约不匹配" }
        val out = outInfo.shape
        require(outInfo.type == OnnxJavaType.FLOAT && out.size == 3 && (out[0] == 1L || out[0] < 0) &&
            out[2] == classes.toLong()) { "REC 输出契约不匹配" }
        session.inputNames.single()
    } catch (e: Exception) { session.close(); throw e }
    private val planeSize = w*h
    private val tensor = FloatArray(3*planeSize)
    private fun normalize(color: Int) = ((color/255.0-mean)/scale).toFloat()
    private val numeric = Regex("(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)")
    fun recognize(frame: LumaFrame, roi: Map<*,*>, displayTurns: Int): Map<String,Any> {
        val id = roi["deviceId"] as String
        return try {
            val l=(roi["l"] as Number).toDouble(); val r=(roi["r"] as Number).toDouble()
            val t=(roi["t"] as Number).toDouble(); val b=(roi["b"] as Number).toDouble()
            val boxW = (r-l)*frame.uprightWidth
            val boxH = (b-t)*frame.uprightHeight
            require(listOf(l,t,r,b).all { it.isFinite() && it in 0.0..1.0 } && boxW >= 2 && boxH >= 2) { "识别框过小或越界" }
            val aspect = if (displayTurns % 2 == 0) boxW/boxH else boxH/boxW
            val resizedWidth = ceil(h*aspect).toInt().coerceIn(1, w)
            tensor.fill(0f)
            for (y in 0 until h) for (x in 0 until resizedWidth) {
                val px=(x+.5)/resizedWidth; val py=(y+.5)/h
                val u=l+(r-l)*inverseX(displayTurns,px,py); val v=t+(b-t)*inverseY(displayTurns,px,py)
                val pixel = frame.interpolatedColor(u, v)
                val i = y*w+x
                tensor[i] = normalize(pixel and 255)
                tensor[planeSize+i] = normalize((pixel shr 8) and 255)
                tensor[2*planeSize+i] = normalize((pixel shr 16) and 255)
            }
            OnnxTensor.createTensor(environment, FloatBuffer.wrap(tensor),longArrayOf(1,3,h.toLong(),w.toLong())).use { value ->
                session.run(mapOf(input to value)).use { result ->
                    val steps=(result[0].value as Array<*>).single() as Array<*>
                    var previous=0; var sum=0.0; var count=0
                    val text=StringBuilder()
                    for (step in steps) {
                        val probs=step as FloatArray
                        require(probs.size == classes && probs.all { it.isFinite() && it in 0f..1f }) { "REC 输出概率无效" }
                        val idx=probs.indices.maxBy { probs[it] }
                        if (idx!=0 && idx!=previous) {
                            text.append(dictionary.getString(idx-1)); count++
                            sum += probs[idx]
                        }
                        previous=idx
                    }
                    val read = text.toString().trim()
                    val confidence = if (count==0) 0.0 else sum/count
                    val row = mapOf("deviceId" to id,"text" to read,"confidence" to confidence)
                    if (numeric.matches(read)) row else row + ("error" to "识别结果不是完整数字，请只框选读数")
                }
            }
        } catch (e:Exception) { mapOf("deviceId" to id,"text" to "","confidence" to 0.0,"error" to (e.message?:"REC 失败")) }
    }
    override fun close() = session.close()
}
