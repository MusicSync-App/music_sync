package com.example.musicsync_app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import java.io.ByteArrayOutputStream
import java.nio.ByteOrder

/**
 * Decodează un fișier audio scurt (MP3 / AAC / Ogg prins din stream-ul radio)
 * în PCM 16 biți intercalat, cu decodoarele hardware/software ale sistemului.
 * Reeșantionarea la 16 kHz mono se face în Dart.
 */
object AudioDecoder {
    private const val TIMEOUT_US = 10_000L
    private const val DEADLINE_MS = 20_000L

    fun decode(path: String, maxSeconds: Int): Map<String, Any> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    track = i
                    format = f
                    break
                }
            }
            if (track < 0 || format == null) throw IllegalStateException("nicio pistă audio")
            extractor.selectTrack(track)

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floatPcm = false
            val out = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            val deadline = System.currentTimeMillis() + DEADLINE_MS

            while (!outputDone && System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex >= 0) {
                    if (info.size > 0) {
                        val buffer = codec.getOutputBuffer(outIndex)!!
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        if (floatPcm) {
                            val floats = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer()
                            val bytes = ByteArray(floats.remaining() * 2)
                            var j = 0
                            while (floats.hasRemaining()) {
                                val v = (floats.get() * 32767f).toInt().coerceIn(-32768, 32767)
                                bytes[j++] = (v and 0xff).toByte()
                                bytes[j++] = ((v shr 8) and 0xff).toByte()
                            }
                            out.write(bytes)
                        } else {
                            val chunk = ByteArray(info.size)
                            buffer.get(chunk)
                            out.write(chunk)
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    if (out.size() >= sampleRate.toLong() * channels * 2 * maxSeconds) outputDone = true
                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    floatPcm = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                        f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                }
            }

            if (out.size() == 0) throw IllegalStateException("decodorul nu a produs audio")
            return mapOf("pcm" to out.toByteArray(), "sampleRate" to sampleRate, "channels" to channels)
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }
}
