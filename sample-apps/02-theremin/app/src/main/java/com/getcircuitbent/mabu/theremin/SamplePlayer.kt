package com.getcircuitbent.mabu.theremin

import android.content.Context
import android.util.Log
import java.io.File
import java.io.InputStream

/**
 * ============================================================================
 * INDEX ROW 27 - playing a sample back, at any speed.
 * ============================================================================
 *
 * Holds the loaded sample and a playhead. One method, [next], returns the next
 * output sample and advances.
 *
 * ---------------------------------------------------------------------------
 * *** PITCH IS PLAYBACK RATE. THIS IS THE WHOLE LESSON. ***
 * ---------------------------------------------------------------------------
 * There is no pitch-shifting algorithm in this file. There is a playhead and
 * an increment:
 *
 *     playhead += increment
 *
 * increment = 1.0 plays at the recorded pitch. 2.0 plays an octave up, and
 * takes half as long. 0.5 plays an octave down, and takes twice as long.
 *
 * Pitch and duration are the SAME control, because a sound's pitch is just how
 * fast you push the waveform past the listener. That identity is not a
 * limitation to work around, it is one of the most useful facts in audio, and
 * it is worth internalising because it explains a pile of other things:
 *
 *   - Varispeed tape, and every "chipmunk" or "slowed and reverb" edit.
 *   - How a classic sampler maps ONE recording across a whole keyboard: each
 *     key is the same audio at a different increment. A twelfth root of two
 *     per semitone.
 *   - Why old samplers sounded "gritty" when pitched up: fewer stored samples
 *     per output sample, so interpolation artifacts get louder.
 *   - Sample-rate conversion. Resampling 44.1k to 48k is this operation with
 *     increment = 44100/48000.
 *
 * The cost is that a held note drifts through the sample instead of sustaining
 * one part of it. Fixing THAT needs granular pitch shifting: two read heads
 * offset by half a grain, crossfaded with a window function, so pitch and
 * speed can move independently. It is maybe forty lines and it would double
 * the size of this file. It is the obvious upgrade and it is deliberately not
 * here, because one line you understand is worth more than forty you copy.
 *
 * ---------------------------------------------------------------------------
 * INTERPOLATION
 * ---------------------------------------------------------------------------
 * The playhead lands between stored samples, so we blend the two either side
 * (linear interpolation). It costs one multiply and loses a little high end.
 * Cubic interpolation sounds better and is the next upgrade if anyone cares;
 * NO interpolation - just truncating the playhead - sounds distinctly bad, and
 * is worth hearing once so you know what it sounds like.
 */
class SamplePlayer {

    /** The loaded audio, mono, normalised to -1..1. */
    private var data: FloatArray = FloatArray(0)

    @Volatile
    var sampleRate: Int = 44100
        private set

    @Volatile
    var label: String = "(none)"
        private set

    val loaded: Boolean get() = data.isNotEmpty()

    /** Length in seconds, for the UI. */
    val durationSec: Float get() = if (sampleRate > 0) data.size.toFloat() / sampleRate else 0f

    private var playhead = 0.0

    /**
     * Playback increment. 1.0 is the recorded pitch. Set by the audio engine
     * from the mapped control, already smoothed.
     */
    @Volatile
    var rate = 1.0f

    /**
     * When a hand is mapped to Position, this is where in the sample it wants
     * the playhead, 0..1. Negative means "nobody is controlling position, just
     * play forward".
     */
    @Volatile
    var positionTarget = -1f

    /**
     * Next output sample, advancing the playhead. Called once per output
     * frame from the audio thread, so it must stay cheap.
     */
    fun next(): Float {
        if (data.isEmpty()) return 0f

        // Position control: rather than jumping the playhead (which clicks
        // horribly), glide toward where the hand is pointing. The glide is
        // heavy because hand data arrives at 10 Hz and is noisy.
        val target = positionTarget
        if (target >= 0f) {
            val want = target.coerceIn(0f, 1f) * (data.size - 1)
            playhead += (want - playhead) * 0.002
        }

        val i = playhead.toInt()
        val frac = (playhead - i).toFloat()
        val a = data[i % data.size]
        val b = data[(i + 1) % data.size]
        val out = a + (b - a) * frac

        playhead += rate.toDouble()
        // Loop. The sample is expected to be loop-friendly; a hard seam here
        // is a click, and no amount of DSP downstream will hide it.
        if (playhead >= data.size) playhead -= data.size
        if (playhead < 0) playhead += data.size

        return out
    }

    fun rewind() {
        playhead = 0.0
    }

    // -----------------------------------------------------------------------
    // LOADING
    // -----------------------------------------------------------------------

    /** Load the sample bundled in assets. */
    fun loadAsset(context: Context, name: String): String? = try {
        context.assets.open(name).use { readWav(it, name) }
    } catch (t: Throwable) {
        "failed to load asset $name: ${t.message}"
    }

    /**
     * Load a WAV from the filesystem, typically /sdcard/theremin/.
     *
     * @return null on success, or a message for the operator.
     */
    fun loadFile(path: String): String? {
        val f = File(path)
        if (!f.isFile) return "not found: $path"
        if (!f.canRead()) return "cannot read $path - granted READ_EXTERNAL_STORAGE?"
        return try {
            f.inputStream().use { readWav(it, f.name) }
        } catch (t: OutOfMemoryError) {
            "out of memory - sample too long. 2 GB of RAM, 32-bit address space"
        } catch (t: Throwable) {
            "failed to load $path: ${t.message}"
        }
    }

    /** Install PCM captured by the recorder add-on. */
    fun loadPcm(samples: FloatArray, rate: Int, label: String) {
        data = samples
        sampleRate = rate
        this.label = label
        playhead = 0.0
    }

    /**
     * Minimal WAV reader: 16-bit PCM, mono or stereo, any sample rate.
     *
     * Written out rather than pulled from a library because it is thirty lines
     * and because seeing a RIFF header parsed once is worth more than a
     * dependency. It handles the one real-world wrinkle - chunks other than
     * fmt and data, which every DAW writes - by skipping anything it does not
     * recognise rather than assuming a fixed 44-byte header.
     */
    private fun readWav(stream: InputStream, name: String): String? {
        val bytes = stream.readBytes()
        if (bytes.size < 44) return "$name is too short to be a WAV"

        fun u16(o: Int) = (bytes[o].toInt() and 0xFF) or ((bytes[o + 1].toInt() and 0xFF) shl 8)
        fun u32(o: Int) = (bytes[o].toInt() and 0xFF) or
            ((bytes[o + 1].toInt() and 0xFF) shl 8) or
            ((bytes[o + 2].toInt() and 0xFF) shl 16) or
            ((bytes[o + 3].toInt() and 0xFF) shl 24)
        fun tag(o: Int) = String(bytes, o, 4, Charsets.US_ASCII)

        if (tag(0) != "RIFF" || tag(8) != "WAVE") return "$name is not a RIFF/WAVE file"

        var channels = 1
        var rate = 44100
        var bits = 16
        var dataOff = -1
        var dataLen = 0

        var p = 12
        while (p + 8 <= bytes.size) {
            val id = tag(p)
            val size = u32(p + 4)
            when (id) {
                "fmt " -> {
                    channels = u16(p + 10)
                    rate = u32(p + 12)
                    bits = u16(p + 22)
                }
                "data" -> {
                    dataOff = p + 8
                    dataLen = size
                }
            }
            // Chunks are word-aligned, so an odd size is followed by a pad byte.
            p += 8 + size + (size and 1)
        }

        if (dataOff < 0) return "$name has no data chunk"
        if (bits != 16) return "$name is $bits-bit; this reader handles 16-bit PCM only"

        val avail = minOf(dataLen, bytes.size - dataOff)
        val frames = avail / 2 / channels
        if (frames <= 0) return "$name contains no audio"

        val out = FloatArray(frames)
        var o = dataOff
        for (i in 0 until frames) {
            // Mono: take the sample. Stereo: average, because everything
            // downstream is mono and summing would clip.
            var acc = 0
            for (c in 0 until channels) {
                acc += (((bytes[o + 1].toInt() and 0xFF) shl 8) or
                    (bytes[o].toInt() and 0xFF)).toShort().toInt()
                o += 2
            }
            out[i] = (acc.toFloat() / channels) / 32768f
        }

        data = out
        sampleRate = rate
        label = "$name · %.1fs · %dk %s".format(
            frames.toFloat() / rate, rate / 1000, if (channels > 1) "stereo->mono" else "mono",
        )
        playhead = 0.0
        Log.i(TAG, "loaded $label")
        return null
    }

    companion object {
        private const val TAG = "MabuSample"

        const val ASSET_SAMPLE = "sample.wav"

        /** Drop your own WAVs here. Created by the install script. */
        const val SDCARD_DIR = "/sdcard/theremin"
    }
}
