package com.getcircuitbent.mabu.theremin

/**
 * ============================================================================
 * What each hand controls.
 * ============================================================================
 *
 * A theremin's whole interface is "where is your hand". This file decides what
 * that number does.
 *
 * The control axis is VERTICAL POSITION. Y is the reliable axis for blob
 * tracking: X is confounded by which side of your face the hand is on, and
 * left/right identity is already the weakest part of the tracker.
 *
 * Blob AREA is the truer theremin axis - it approximates distance from the
 * camera, which is what a real theremin's antennae actually sense - and
 * switching to it is one line in [readAxis]. It is left as a documented
 * change rather than another dropdown because two hands times six parameters
 * is already enough combinations to explore.
 *
 * Note that screen Y runs DOWNWARD: 0 is the top of the frame. Every mapping
 * below inverts it, because "higher hand means more" is what every human
 * expects and the opposite feels broken within about two seconds.
 */
enum class HandParam(val label: String) {
    NONE("None"),
    VOLUME("Volume"),
    PITCH("Pitch"),
    POSITION("Position"),
    LOW_PASS("Low-pass"),
    HIGH_PASS("High-pass"),
    ;

    companion object {
        val ALL = values().toList()
    }
}

object Mapping {

    /**
     * Read the control value from a hand, as 0..1 with 1 meaning "hand high".
     *
     * To use distance-from-camera instead of height, return
     * `(hand.area / TYPICAL_AREA).coerceIn(0f, 1f)` here. Bigger blob means
     * closer, which is the axis a real theremin senses.
     */
    fun readAxis(hand: BlobExtractor.Hand): Float = (1f - hand.y).coerceIn(0f, 1f)

    /**
     * Apply one hand's control value to the engine.
     *
     * Ranges are chosen to be playable rather than maximal. A pitch control
     * spanning ten octaves is impressive for four seconds and unusable after
     * that; two octaves either side of unity is an instrument.
     */
    fun apply(param: HandParam, value: Float, audio: AudioEngine) {
        when (param) {
            HandParam.NONE -> Unit

            HandParam.VOLUME -> audio.targetVolume = value

            // 0.25x to 4x, exponential so equal hand movements give equal
            // musical intervals. Linear would put every useful pitch in the
            // bottom third of the range. 4^(2v-1): v=0.5 is unity.
            HandParam.PITCH -> audio.targetRate = Math.pow(4.0, (value * 2f - 1f).toDouble()).toFloat()

            HandParam.POSITION -> audio.targetPosition = value

            HandParam.LOW_PASS -> {
                audio.filterMode = Filter.Mode.LOW_PASS
                audio.targetCutoff = value
            }

            HandParam.HIGH_PASS -> {
                audio.filterMode = Filter.Mode.HIGH_PASS
                // Inverted: hand UP opens the filter by REMOVING more bass,
                // so "up" still means "more effect" as it does everywhere else.
                audio.targetCutoff = value
            }
        }
    }

    /**
     * Reset anything a parameter owns when no hand is controlling it.
     *
     * Without this, dropping a hand freezes its parameter at whatever value it
     * last had. For volume that is harmless (the gate handles silence), but a
     * filter stuck at its lowest cutoff sounds like the instrument broke.
     */
    fun release(param: HandParam, audio: AudioEngine) {
        when (param) {
            HandParam.VOLUME -> audio.targetVolume = 0.8f
            HandParam.PITCH -> audio.targetRate = 1f
            HandParam.POSITION -> audio.targetPosition = -1f
            HandParam.LOW_PASS, HandParam.HIGH_PASS -> {
                audio.filterMode = Filter.Mode.OFF
            }
            HandParam.NONE -> Unit
        }
    }
}
