package com.apkbridge.host

import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Bundle
import android.util.Log
import android.view.Surface
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

class AvcScreenStreamer(
    private val mediaProjection: MediaProjection,
    rawWidth: Int,
    rawHeight: Int,
    private val densityDpi: Int,
    private val port: Int = 5567
) {
    private val tag = "AvcScreenStreamer"
    val width: Int = (rawWidth / 16) * 16
    val height: Int = (rawHeight / 16) * 16

    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var virtualDisplay: VirtualDisplay? = null

    private val clients = CopyOnWriteArrayList<ClientWriter>()
    @Volatile
    private var cachedConfigPacket: ByteArray? = null

    private class ClientWriter(val socket: Socket, val out: DataOutputStream) {
        val lock = Any()
    }

    fun start() {
        if (!running.compareAndSet(false, true)) return

        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, 3_000_000)
                setInteger(MediaFormat.KEY_FRAME_RATE, 60)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
            }

            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = codec.createInputSurface()
            codec.start()

            mediaCodec = codec
            inputSurface = surface
            virtualDisplay = mediaProjection.createVirtualDisplay(
                "ApkBridgeDisplay",
                width,
                height,
                densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                surface,
                null,
                null
            )

            Thread({ acceptLoop() }, "ApkBridge-StreamAccept").start()
            Thread({ encodeLoop(codec) }, "ApkBridge-EncodeLoop").start()
            Log.i(tag, "Started H.264 stream ${width}x${height} on port $port")
        } catch (e: Exception) {
            Log.e(tag, "Failed to start streamer", e)
            stop()
        }
    }

    private fun acceptLoop() {
        try {
            val server = ServerSocket(port)
            serverSocket = server
            while (running.get()) {
                val sock = server.accept()
                sock.tcpNoDelay = true
                sock.sendBufferSize = 262_144
                val writer = ClientWriter(sock, DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 65_536)))
                clients.add(writer)
                Log.i(tag, "Stream client connected: ${sock.inetAddress.hostAddress}")

                cachedConfigPacket?.let { cfg ->
                    sendPacket(writer, 1, 0L, cfg)
                }
                requestKeyFrame()
            }
        } catch (e: Exception) {
            if (running.get()) Log.e(tag, "Accept loop error", e)
        }
    }

    private fun encodeLoop(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (running.get()) {
            try {
                val idx = codec.dequeueOutputBuffer(info, 16_000L)
                if (idx >= 0) {
                    val outBuf = codec.getOutputBuffer(idx)
                    if (outBuf != null && info.size > 0) {
                        val bytes = ByteArray(info.size)
                        outBuf.position(info.offset)
                        outBuf.limit(info.offset + info.size)
                        outBuf.get(bytes)

                        val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                        if (isConfig) {
                            cachedConfigPacket = bytes
                        }

                        val flagByte: Byte = when {
                            isConfig -> 1
                            isKey -> 2
                            else -> 0
                        }

                        for (client in clients) {
                            sendPacket(client, flagByte, info.presentationTimeUs, bytes)
                        }
                    }
                    codec.releaseOutputBuffer(idx, false)
                }
            } catch (e: Exception) {
                if (running.get()) Log.e(tag, "Encode loop error", e)
                break
            }
        }
    }

    private fun sendPacket(client: ClientWriter, flags: Byte, ptsUs: Long, payload: ByteArray) {
        try {
            synchronized(client.lock) {
                client.out.writeInt(payload.size)
                client.out.writeByte(flags.toInt())
                client.out.writeLong(ptsUs)
                client.out.write(payload)
                client.out.flush()
            }
        } catch (_: Exception) {
            clients.remove(client)
            try { client.socket.close() } catch (_: Exception) {}
        }
    }

    fun requestKeyFrame() {
        try {
            val params = Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            }
            mediaCodec?.setParameters(params)
        } catch (_: Exception) {
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        for (c in clients) {
            try { c.socket.close() } catch (_: Exception) {}
        }
        clients.clear()
        try { serverSocket?.close() } catch (_: Exception) {}
        try { virtualDisplay?.release() } catch (_: Exception) {}
        try { mediaCodec?.stop() } catch (_: Exception) {}
        try { mediaCodec?.release() } catch (_: Exception) {}
        try { inputSurface?.release() } catch (_: Exception) {}
        serverSocket = null
        virtualDisplay = null
        mediaCodec = null
        inputSurface = null
    }
}
