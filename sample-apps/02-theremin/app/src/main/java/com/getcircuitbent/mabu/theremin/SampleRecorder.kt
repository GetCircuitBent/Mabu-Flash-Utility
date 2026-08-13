package com.getcircuitbent.mabu.theremin

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log

/**
 * ============================================================================
 * INDEX ROW 17 - recording your own sample. OPT-IN.
 * ============================================================================
 *
 * *** THIS IS SWITCHED OFF. *** RECORD_AUDIO is commented out in
 * AndroidManifest.xml, so [start] will fail until you turn it on:
 *
 *   1. Uncomment the RECORD_AUDIO line in AndroidManifest.xml
 *   2. Rebuild and reinstall
 *   3. adb shell pm grant com.getcircuitbent.mabu.theremin \
 *        android.permission.RECORD_AUDIO
 *   4. Wire a button to this class in MainActivity (about ten lines)
 *
 * Same two-step shape as autostart in Sample App 1, and for the same reason:
 * switching on a microphone is a decision somebody should make on purpose, not
 * inherit from a sample they installed to have a look at. A sample app that
 * quietly holds RECORD_AUDIO is a sample app nobody should trust.
 *
 * ---------------------------------------------------------------------------
 * WHAT IT DOES
 * ---------------------------------------------------------------------------
 * Records a few seconds of mono PCM and hands it to [SamplePlayer], so the
 * thing you are playing becomes something you just made. It is the most fun
 * feature in the app and it is four dozen lines, because AudioRecord is the
 * mirror image of AudioTrack: make one, read blocks in a loop, stop.
 *
 * ---------------------------------------------------------------------------
 * TWO THINGS WORTH KNOWING
 * ---------------------------------------------------------------------------
 * SAMPLE RATE. Recording at 16 kHz and playing through a 44.1 kHz engine
 * means the audio comes out roughly 2.75x too fast and an octave and a half
 * too high, unless you account for it. This class records at the ENGINE's
 * rate to keep that from being a surprise. If you drop it to 16 kHz for a
 * smaller buffer, resample on the way in, or set the player's rate to
 * 16000/44100 to compensate - which, note, is exactly the pitch-equals-rate
 * identity from SamplePlayer, doing something useful.
 *
 * VOICE_RECOGNITION, not MIC. The VOICE_RECOGNITION source usually bypasses
 * the aggressive AGC and noise suppression that the default applies, and
 * those make a mess of anything musical: AGC pumps, and noise suppression
 * eats sustained tones because they look like background hum to it.
 */
class SampleRecorder {

    @Volatile
    var recording = false
        private set

    private var thread: Thread? = null

    /**
     * Record for up to [maxSeconds], then hand the audio to [player].
     *
     * @param onDone called off the main thread with null on success, or a
     *        message to show the operator.
     */
    fun start(player: SamplePlayer, maxSeconds: Float = 4f, onDone: (String?) -> Unit) {
        if (recording) return

        val rate = AudioEngine.SAMPLE_RATE
        val minBuf = AudioRecord.getMinBufferSize(
            rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            onDone("AudioRecord unavailable at ${rate}Hz")
            return
        }

        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, 4096) * 2,
            )
        } catch (t: Throwable) {
            // The overwhelmingly likely cause is the permission being absent,
            // which is the default state of this app. Say so.
            onDone("Cannot open mic: is RECORD_AUDIO uncommented and granted?")
            return
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            onDone("Mic failed to initialise: is RECORD_AUDIO granted?")
            return
        }

        recording = true
        thread = Thread({
            val total = (rate * maxSeconds).toInt()
            val out = FloatArray(total)
            val block = ShortArray(2048)
            var written = 0
            try {
                record.startRecording()
                while (recording && written < total) {
                    val n = record.read(block, 0, block.size)
                    if (n <= 0) break
                    for (i in 0 until n) {
                        if (written >= total) break
                        out[written++] = block[i] / 32768f
                    }
                }
            } catch (t: Throwable) {
                Log.e(TAG, "record failed", t)
            } finally {
                try {
                    record.stop()
                } catch (_: Throwable) {
                }
                record.release()
                recording = false
            }

            if (written < rate / 4) {
                onDone("Recording too short")
                return@Thread
            }

            // Fade the ends so the loop seam is not a click. Same reasoning as
            // the gate ramp in AudioEngine: any discontinuity in a waveform is
            // audible, and a looping sample crosses its seam constantly.
            val fade = (rate * 0.02f).toInt()
            for (i in 0 until minOf(fade, written / 2)) {
                val g = i.toFloat() / fade
                out[i] *= g
                out[written - 1 - i] *= g
            }

            player.loadPcm(out.copyOf(written), rate, "recorded · %.1fs".format(written.toFloat() / rate))
            onDone(null)
        }, "mabu-record").apply { start() }
    }

    /** Stop early. The audio captured so far is kept. */
    fun stop() {
        recording = false
    }

    companion object {
        private const val TAG = "MabuRecord"
    }
}
