package com.getcircuitbent.mabu.theremin

import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Process
import android.util.Log
import kotlin.math.pow

/**
 * ============================================================================
 * INDEX ROWS 18 AND 27 - the instrument.
 * ============================================================================
 *
 * An AudioTrack, a thread, and a loop that fills blocks of samples. About two
 * hundred lines, and it is a playable instrument.
 *
 * ---------------------------------------------------------------------------
 * *** THE RATE PROBLEM. THIS IS THE POINT OF THE FILE. ***
 * ---------------------------------------------------------------------------
 * The camera gives us hand positions 10 TIMES A SECOND. The audio runs at
 * 44,100 SAMPLES A SECOND. Those numbers differ by a factor of four thousand.
 *
 * If you take the naive route and apply each new hand position directly:
 *
 *     volume = handHeight          // <-- every 100 ms, a step change
 *
 * you get a staircase. On volume that is a click every tenth of a second. On
 * pitch it is the sound people call "zipper noise". It is instantly audible
 * and it makes the whole thing sound broken rather than lo-fi.
 *
 * The fix is the same one MotorTween uses on the motors, and meeting it twice
 * in two different domains is the fastest way to learn it:
 *
 *     PRODUCERS WRITE TARGETS. A CONSUMER ON ITS OWN CLOCK INTERPOLATES.
 *
 * The camera thread writes [targetVolume], [targetRate] and the rest, and then
 * forgets about it. This thread, every block, ramps each parameter LINEARLY
 * from where it was to where the target is, across the block's samples. A
 * 100 ms jump becomes a smooth 23 ms glide per block instead of a step.
 *
 * In app 1 the same pattern stops servos chattering. Here it stops audio
 * zippering. It is the single most transferable idea in either sample.
 *
 * ---------------------------------------------------------------------------
 * THE GATE: WHY THIS DOES NOT JUST SCREAM
 * ---------------------------------------------------------------------------
 * A sampler with a loop and no gate is a device that makes noise forever.
 * Playback is gated on HAND PRESENCE, not on any volume mapping, so it cannot
 * be configured into screaming: no hands in frame, no sound, whatever the
 * dropdowns say. A real theremin is silent until you enter its field, and this
 * is the same idea.
 *
 * Two subtleties, both learned the hard way in other projects:
 *
 *  - GRACE. Hand tracking drops a frame when you turn your palm or cross in
 *    front of something. Gating off instantly makes sustained notes stutter,
 *    so silence has to be CONFIRMED over [graceMs] before it is acted on.
 *    Exactly the same reasoning as face-loss grace in app 1.
 *  - FADE. Cutting amplitude to zero between one sample and the next is a
 *    discontinuity in the waveform, and a discontinuity is a CLICK. Every gate
 *    transition ramps over [fadeMs]. This is why gates in real instruments
 *    have attack and release times, and it is not a stylistic choice.
 */
class AudioEngine(private val player: SamplePlayer) {

    // -----------------------------------------------------------------------
    // TARGETS - written by the camera thread, read here
    // -----------------------------------------------------------------------

    @Volatile var targetVolume = 0.8f
    @Volatile var targetRate = 1.0f
    @Volatile var targetCutoff = 0.5f          // 0..1, mapped to Hz below
    @Volatile var targetPosition = -1f         // <0 = not controlled

    /** Set by the tracker: is at least one hand visible right now. */
    @Volatile var handsPresent = false

    /** Operator switch. False means silence regardless of hands. */
    @Volatile var armed = true

    /** Always-available level control, independent of any mapping. */
    @Volatile var masterGain = 0.8f

    @Volatile var filterMode = Filter.Mode.OFF

    /** Confirmed-absent time before gating off. */
    @Volatile var graceMs = 250L

    /** Gate ramp length. Shorter than about 5 ms and you will hear the edge. */
    @Volatile var fadeMs = 150L

    // -----------------------------------------------------------------------
    // Current (ramped) values. Audio thread only.
    // -----------------------------------------------------------------------
    private var curVolume = 0f
    private var curRate = 1f
    private var curCutoff = 0.5f
    private var gate = 0f                      // 0 silent, 1 open

    private var lastHandSeenMs = 0L

    private var track: AudioTrack? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    private lateinit var filter: Filter
    private val buffer = ShortArray(BLOCK)

    @Volatile var underruns = 0; private set
    @Volatile var active = false; private set

    fun start() {
        if (running) return
        val rate = SAMPLE_RATE
        filter = Filter(rate)

        val minBuf = AudioTrack.getMinBufferSize(
            rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        // Four blocks, or whatever the system insists on. Too small and the
        // RK3288 underruns whenever the camera thread gets busy; too large and
        // you can feel the latency when you move your hand.
        val bufSize = maxOf(minBuf, BLOCK * 2 * 4)

        val t = AudioTrack(
            AudioManager.STREAM_MUSIC,
            rate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize,
            AudioTrack.MODE_STREAM,
        )
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            Log.e(TAG, "AudioTrack failed to initialise")
            return
        }
        track = t
        running = true
        t.play()

        thread = Thread({
            // Audio threads must outrank everything else. If the camera or UI
            // preempts this loop, the buffer runs dry and you hear it.
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            renderLoop(t)
        }, "mabu-audio").apply { start() }

        Log.i(TAG, "audio started: ${rate}Hz mono, block $BLOCK, buffer $bufSize")
    }

    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        try {
            track?.stop()
            track?.release()
        } catch (_: Throwable) {
        }
        track = null
        active = false
    }

    /**
     * Fill and write one block at a time, forever. Blocking on write() is what
     * paces the loop: AudioTrack accepts data only as fast as it plays it, so
     * this thread spends most of its life asleep inside write().
     */
    private fun renderLoop(t: AudioTrack) {
        while (running) {
            renderBlock()
            val written = t.write(buffer, 0, BLOCK)
            if (written < 0) {
                Log.w(TAG, "AudioTrack.write returned $written")
                underruns++
            }
        }
    }

    private fun renderBlock() {
        val now = System.currentTimeMillis()

        // --- Gate ---------------------------------------------------------
        if (handsPresent) lastHandSeenMs = now
        val withinGrace = (now - lastHandSeenMs) < graceMs
        val wantOpen = armed && (handsPresent || withinGrace) && player.loaded
        val gateStep = BLOCK.toFloat() / (fadeMs / 1000f * SAMPLE_RATE)
        val gateTarget = if (wantOpen) 1f else 0f

        // --- Per-block parameter ramps ------------------------------------
        // The whole anti-zipper mechanism. Each parameter gets a per-sample
        // increment that walks it from where it is to its target across
        // exactly this block, so nothing ever steps.
        val volStart = curVolume
        val volEnd = if (wantOpen) targetVolume * masterGain else curVolume
        val volStep = (volEnd - volStart) / BLOCK

        val rateStart = curRate
        val rateEnd = targetRate.coerceIn(0.25f, 4f)
        val rateStep = (rateEnd - rateStart) / BLOCK

        val cutStart = curCutoff
        val cutEnd = targetCutoff.coerceIn(0f, 1f)
        val cutStep = (cutEnd - cutStart) / BLOCK

        filter.mode = filterMode
        player.positionTarget = targetPosition

        var v = volStart
        var r = rateStart
        var c = cutStart
        var g = gate

        for (i in 0 until BLOCK) {
            v += volStep
            r += rateStep
            c += cutStep
            g += if (g < gateTarget) gateStep else -gateStep
            g = g.coerceIn(0f, 1f)

            player.rate = r

            // Cutoff is set per block, not per sample: recomputing sin() 1024
            // times per block would cost more than the whole rest of the loop,
            // and the ear cannot tell.
            if (i == 0 && filterMode != Filter.Mode.OFF) {
                filter.setCutoff(cutoffHz(c))
            }

            var s = player.next()
            s = filter.process(s)
            s *= v * g

            // Clip rather than wrap. An overflowing short wraps from +full to
            // -full, which is the loudest, ugliest sound a computer can make.
            val out = (s * 32767f).toInt().coerceIn(-32767, 32767)
            buffer[i] = out.toShort()
        }

        curVolume = v
        curRate = r
        curCutoff = c
        gate = g
        active = g > 0.001f
    }

    /**
     * Map a 0..1 control to a cutoff frequency, EXPONENTIALLY.
     *
     * Linear frequency mapping feels wrong to play: pitch perception is
     * logarithmic, so half of a linear sweep is spent in the top octave where
     * nothing much changes, and the musically interesting bottom end is
     * crammed into the first few percent. Two decades from 80 Hz to 8 kHz
     * spreads it the way an ear expects.
     */
    private fun cutoffHz(control: Float): Float =
        80f * 10f.pow(control.coerceIn(0f, 1f) * 2f)

    companion object {
        private const val TAG = "MabuAudio"

        /**
         * 44.1 kHz mono. Drop to 22050 if the SoC struggles; everything
         * downstream reads this constant.
         */
        const val SAMPLE_RATE = 44100

        /**
         * Samples per block. About 23 ms at 44.1 kHz.
         *
         * This is the latency/underrun dial. Smaller feels more immediate and
         * risks the buffer running dry when the camera thread is busy; larger
         * is safe and sluggish. If the perf line shows underruns, raise it and
         * record the number that worked in the README.
         */
        const val BLOCK = 1024
    }
}
