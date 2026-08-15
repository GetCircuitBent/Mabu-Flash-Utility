package com.getcircuitbent.mabu.theremin

import kotlin.math.PI
import kotlin.math.sin

/**
 * ============================================================================
 * INDEX ROW 27 - one filter, two outputs.
 * ============================================================================
 *
 * A Chamberlin state-variable filter. Three lines of arithmetic per sample
 * that give you a low-pass AND a high-pass from the same state, which is why
 * the mapping dropdown can offer both without a second implementation.
 *
 *     low  += f * band
 *     high  = input - low - q * band
 *     band += f * high
 *
 * Two state variables (low and band) carry the filter's memory. The tuning
 * coefficient f is derived from the cutoff, and q sets resonance.
 *
 * ---------------------------------------------------------------------------
 * *** THE STABILITY LIMIT, WHICH WILL BITE YOU ***
 * ---------------------------------------------------------------------------
 *     f = 2 * sin(pi * cutoff / sampleRate)
 *
 * This approximation is only valid while the cutoff is well below the sample
 * rate. As cutoff approaches sampleRate/6 the filter stops being a filter and
 * becomes an oscillator: the state variables grow without bound and the output
 * turns into full-scale noise. At 44,100 Hz that limit is about 7 kHz.
 *
 * It is a genuinely nasty failure because it does not sound like a bug, it
 * sounds like the filter "opening up" and then exploding, and it only happens
 * when someone sweeps the control to the top - which is the first thing anyone
 * does with a filter.
 *
 * So the cutoff is clamped at MAX_CUTOFF_RATIO below, and the state is checked
 * for divergence as a backstop. Do not remove either.
 */
class Filter(private val sampleRate: Int) {

    enum class Mode { OFF, LOW_PASS, HIGH_PASS }

    @Volatile
    var mode = Mode.OFF

    private var low = 0f
    private var band = 0f

    /** Resonance. 1/q; higher q here means less resonance. 1.4 is gentle. */
    private var q = 1.4f

    private var f = 0.5f

    /**
     * Set the cutoff in Hz. Clamped to the stable range; see the class
     * comment before widening it.
     */
    fun setCutoff(hz: Float) {
        val maxHz = sampleRate * MAX_CUTOFF_RATIO
        val c = hz.coerceIn(MIN_CUTOFF_HZ, maxHz)
        f = (2.0 * sin(PI * c / sampleRate)).toFloat()
    }

    fun reset() {
        low = 0f
        band = 0f
    }

    /** Process one sample. Returns it unchanged when [mode] is OFF. */
    fun process(input: Float): Float {
        if (mode == Mode.OFF) return input

        low += f * band
        val high = input - low - q * band
        band += f * high

        // Divergence backstop. If the filter has been pushed unstable by a
        // parameter change mid-block, reset rather than emit full-scale noise
        // into someone's speakers.
        if (!low.isFinite() || !band.isFinite() || low > 1e3f || low < -1e3f) {
            reset()
            return input
        }

        return if (mode == Mode.LOW_PASS) low else high
    }

    companion object {
        /**
         * Cutoff ceiling as a fraction of the sample rate. The theoretical
         * limit is about 1/6; 1/8 leaves margin for the resonance term.
         */
        private const val MAX_CUTOFF_RATIO = 0.125f
        private const val MIN_CUTOFF_HZ = 40f
    }
}
