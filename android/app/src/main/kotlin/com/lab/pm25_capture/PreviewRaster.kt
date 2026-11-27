package com.lab.pm25_capture

import android.opengl.EGL14.*
import android.opengl.EGLExt
import android.opengl.GLES20.*
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** YUV to RGB on the GPU. Like OCR this uses the already-cropped analysis image,
 * with the same inverse rotation, rather than a separately cropped preview stream. */
internal class PreviewRaster(private val entry: TextureRegistry.SurfaceTextureEntry) : AutoCloseable {
    private val display = eglGetDisplay(EGL_DEFAULT_DISPLAY)
    private var initialized = false
    private var context = EGL_NO_CONTEXT
    private var window = EGL_NO_SURFACE
    private var surface: Surface? = null
    private var program = 0
    private val textures = IntArray(3)
    private var size = 0 to 0
    private val upload = arrayOfNulls<ByteBuffer>(3)
    private val vertices = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val corners = floatArrayOf(-1f, 1f, -1f, -1f, 1f, 1f, 1f, -1f)
    private var lastRotation = -1
    private var position = -1
    private var coordinates = -1
    private var pixels = -1
    private var chroma = -1
    private var offset = -1

    private fun shader(type: Int, code: String): Int {
        val id = glCreateShader(type)
        glShaderSource(id, code)
        glCompileShader(id)
        val status = IntArray(1)
        glGetShaderiv(id, GL_COMPILE_STATUS, status, 0)
        check(status[0] != 0) { glGetShaderInfoLog(id) }
        return id
    }

    private fun initialize(frame: LumaFrame) {
        val version = IntArray(2)
        check(eglInitialize(display, version, 0, version, 1)) { "无法初始化预览 EGL" }
        initialized = true
        val attrs = intArrayOf(EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE)
        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val count = IntArray(1)
        check(eglChooseConfig(display, attrs, 0, configs, 0, 1, count, 0) && count[0] > 0) { "无可用预览 EGL 配置" }
        val config = checkNotNull(configs[0])
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, intArrayOf(EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE), 0)
        check(context != EGL_NO_CONTEXT) { "创建预览 EGL 上下文失败" }
        entry.surfaceTexture().setDefaultBufferSize(frame.uprightWidth, frame.uprightHeight)
        surface = Surface(entry.surfaceTexture())
        window = eglCreateWindowSurface(display, config, surface, intArrayOf(EGL_NONE), 0)
        check(window != EGL_NO_SURFACE && eglMakeCurrent(display, window, window, context)) { "创建预览 EGL 表面失败" }
        val vertex = shader(GL_VERTEX_SHADER, """
            attribute vec2 position;
            attribute vec2 coordinate;
            varying vec2 uv;
            void main() { gl_Position = vec4(position, 0., 1.); uv = coordinate; }
        """.trimIndent())
        val fragment = shader(GL_FRAGMENT_SHADER, """
            precision highp float;
            varying vec2 uv;
            uniform sampler2D yTex;
            uniform sampler2D uTex;
            uniform sampler2D vTex;
            uniform vec2 pixels;
            uniform vec2 chroma;
            uniform vec2 offset;
            void main() {
                vec2 p = clamp(floor(uv * pixels), vec2(0.), pixels - vec2(1.));
                vec2 c = (floor((p + offset) / 2.) + .5) / chroma;
                float y = max(0., texture2D(yTex, (p + .5) / pixels).r - 16. / 255.) * 1.1640625;
                float u = texture2D(uTex, c).r - 128. / 255.;
                float v = texture2D(vTex, c).r - 128. / 255.;
                gl_FragColor = vec4(y + 1.59765625 * v, y - .390625 * u - .8125 * v, y + 2.015625 * u, 1.);
            }
        """.trimIndent())
        program = glCreateProgram()
        glAttachShader(program, vertex)
        glAttachShader(program, fragment)
        glLinkProgram(program)
        glDeleteShader(vertex)
        glDeleteShader(fragment)
        val linked = IntArray(1)
        glGetProgramiv(program, GL_LINK_STATUS, linked, 0)
        check(linked[0] != 0) { glGetProgramInfoLog(program) }
        glUseProgram(program)
        position = glGetAttribLocation(program, "position")
        coordinates = glGetAttribLocation(program, "coordinate")
        pixels = glGetUniformLocation(program, "pixels")
        chroma = glGetUniformLocation(program, "chroma")
        offset = glGetUniformLocation(program, "offset")
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
        glGenTextures(textures.size, textures, 0)
        val names = arrayOf("yTex", "uTex", "vTex")
        for (i in textures.indices) {
            glActiveTexture(GL_TEXTURE0 + i)
            glBindTexture(GL_TEXTURE_2D, textures[i])
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
            glUniform1i(glGetUniformLocation(program, names[i]), i)
        }
    }

    fun draw(frame: LumaFrame) {
        if (program == 0) initialize(frame)
        val resize = size.first != frame.width || size.second != frame.height
        if (resize) size = frame.width to frame.height
        if (lastRotation != frame.rotation) {
            lastRotation = frame.rotation
            vertices.clear()
            for (i in 0..3) {
                val x = corners[i * 2]; val y = corners[i * 2 + 1]
                val u = (x + 1.0) / 2; val v = (1.0 - y) / 2
                vertices.put(x).put(y).put(inverseX(lastRotation/90, u, v).toFloat()).put(inverseY(lastRotation/90, u, v).toFloat())
            }
        }
        glViewport(0, 0, frame.uprightWidth, frame.uprightHeight)
        glUniform2f(pixels, frame.width.toFloat(), frame.height.toFloat())
        glUniform2f(chroma, frame.chromaWidth.toFloat(), frame.chromaHeight.toFloat())
        glUniform2f(offset, frame.chromaOffsetX.toFloat(), frame.chromaOffsetY.toFloat())
        for (i in textures.indices) {
            val w = if (i == 0) frame.width else frame.chromaWidth
            val h = if (i == 0) frame.height else frame.chromaHeight
            val buf = upload[i]?.takeIf { it.capacity() == w*h } ?: ByteBuffer.allocateDirect(w*h).also { upload[i] = it }
            buf.clear(); frame.copyPlane(i, buf); buf.flip()
            glActiveTexture(GL_TEXTURE0 + i)
            if (resize) glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, w, h, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, buf)
            else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_LUMINANCE, GL_UNSIGNED_BYTE, buf)
        }
        vertices.position(0)
        glVertexAttribPointer(position, 2, GL_FLOAT, false, 16, vertices)
        glEnableVertexAttribArray(position)
        vertices.position(2)
        glVertexAttribPointer(coordinates, 2, GL_FLOAT, false, 16, vertices)
        glEnableVertexAttribArray(coordinates)
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
        EGLExt.eglPresentationTimeANDROID(display, window, frame.sensorTimeNs)
        check(eglSwapBuffers(display, window)) { "预览交换缓冲区失败" }
    }

    override fun close() {
        if (context != EGL_NO_CONTEXT) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)
            if (window != EGL_NO_SURFACE) eglDestroySurface(display, window)
            eglDestroyContext(display, context)
        }
        if (initialized) eglTerminate(display)
        eglReleaseThread()
        surface?.release()
    }
}
