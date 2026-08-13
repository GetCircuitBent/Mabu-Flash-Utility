package com.getcircuitbent.mabu.theremin

import kotlin.math.floor

/**
 * ============================================================================
 * INDEX ROWS 2, 4 AND 5 - the wire protocol, the motor table, and frames.
 * ============================================================================
 *
 * Pure functions only. Nothing here touches the serial port or holds state,
 * which means you can call any of it from a unit test on your laptop with no
 * device attached. [selfTest] does exactly that.
 *
 * This is the file to read if you want to speak to the motor board from some
 * other language - it is a complete description of the protocol.
 *
 * ---------------------------------------------------------------------------
 * FRAME FORMAT
 * ---------------------------------------------------------------------------
 *
 *     FA 00 <payload_len> <payload bytes...> <checksum_s2> <checksum_s1>
 *
 *   - The header is always FA 00.
 *   - payload_len is a single byte: the number of payload bytes.
 *   - The checksum is Fletcher-8 MOD 255 (not 256), computed over the ENTIRE
 *     frame INCLUDING the FA 00 header, and appended s2 first, then s1.
 *
 * A motor-move payload looks like:
 *
 *     01 <bitmask> 01 <value bytes, one per set bit, MSB-first>
 *
 * ---------------------------------------------------------------------------
 * THE TWO WAYS THIS GOES WRONG SILENTLY
 * ---------------------------------------------------------------------------
 * 1. WRONG BITMASK. The board discards a frame whose bitmask does not match
 *    the number of value bytes. No error, no movement, no reply. If you send
 *    what looks like a perfect frame and nothing moves, count your bytes.
 *
 * 2. WRONG VALUE ORDER. Values must appear in MSB-first bitmask order:
 *    LDL, LDR, ELR, EUD, NE, NR, NT. Send them in a different order and the
 *    board happily moves the wrong motors.
 *
 * There is also a trap that is NOT silent but is very easy to get wrong; see
 * [wire] below.
 */
object MabuProtocol {

    // -----------------------------------------------------------------------
    // ROW 4: THE MOTOR TABLE
    // -----------------------------------------------------------------------
    // Seven motors, each one bit in the mask. The bit values are fixed by the
    // motor board - do not renumber them.
    //
    // IMPORTANT: the neutrals and directions below are for the unit this
    // sample was developed against. Motor polarity DOES vary between Mabus.
    // Before trusting any of it on your unit, open the app, drag each slider,
    // and watch what actually happens. That is what the sliders are for.

    const val LDL = 0x40  // Eyelid, Left
    const val LDR = 0x20  // Eyelid, Right
    const val ELR = 0x10  // Eyes, Left/Right (pan)
    const val EUD = 0x08  // Eyes, Up/Down (tilt)
    const val NE  = 0x04  // Neck Elevation (pitch)
    const val NR  = 0x02  // Neck Rotation (yaw)
    const val NT  = 0x01  // Neck Tilt (roll)

    /** All seven motors at once. */
    const val ALL = 0x7F

    /**
     * The motors in MSB-first order. Value bytes in a frame MUST follow this
     * order, so everything else in the app derives its ordering from here
     * rather than repeating it.
     */
    val MOTORS: List<Motor> = listOf(
        //          bit  name           neutral  low value means...     high value means...
        Motor(LDL, "LDL", "Eyelid L",       20f, "open (0 = hard stop)", "closed"),
        Motor(LDR, "LDR", "Eyelid R",       20f, "open (0 = hard stop)", "closed"),
        Motor(ELR, "ELR", "Eyes L/R",       50f, "look left",            "look right"),
        Motor(EUD, "EUD", "Eyes U/D",       50f, "look UP (inverted!)",  "look down"),
        Motor(NE,  "NE",  "Neck Elev",      50f, "head down",            "head up"),
        Motor(NR,  "NR",  "Neck Rot",       50f, "turn right",           "turn left"),
        Motor(NT,  "NT",  "Neck Tilt",      50f, "tilt right",           "tilt left"),
    )

    data class Motor(
        val bit: Int,
        val code: String,
        val label: String,
        val neutral: Float,
        val lowMeans: String,
        val highMeans: String,
    )

    /**
     * Every motor's full travel is 0..100 on this unit, with no grinding at
     * either end.
     *
     * Two warnings that have cost real time:
     *  - Community documentation claims neck elevation stops at 50. It does
     *    not. Full range is real and confirmed.
     *  - EUD is INVERTED: 0 makes the eyes look UP. Do not "fix" this by
     *    flipping it here; the whole app is written against the real values.
     */
    const val MIN = 0f
    const val MAX = 100f

    /** Eyelid values used by poses and blinks. Higher = more closed. */
    const val EYELID_WIDE   = 0f    // mechanical hard stop, wide open
    const val EYELID_OPEN   = 20f   // the neutral resting position
    const val EYELID_CLOSED = 100f  // fully shut

    // -----------------------------------------------------------------------
    // ROW 2: VALUE ENCODING
    // -----------------------------------------------------------------------

    /**
     * Convert a logical 0..100 value into the 0..255 byte the board wants.
     *
     * ***********************************************************************
     * THE FLOATING-POINT TRAP. READ THIS ONE.
     * ***********************************************************************
     * The scale factor is 2.55, so the obvious implementation is:
     *
     *     (value * 2.55).roundToInt()          // <-- WRONG
     *
     * For value = 50 (dead centre, the single most-sent value in the whole
     * protocol) that gives 127, not 128. The reason is that neither 2.55 nor
     * the product is exactly representable in binary floating point:
     * 50 * 2.55 evaluates to 127.49999999999999, and rounding that gives 127.
     *
     * Doing the division LAST keeps it exact: 50 * 255 = 12750, and
     * 12750 / 100.0 = 127.5 exactly, so floor(127.5 + 0.5) = 128.
     *
     * Is one wire step out of 255 visible on the robot? No. But the frames in
     * MABU_MOTOR_GUIDE.md are byte-for-byte, and if your encoder disagrees
     * with the documented frames you will waste an afternoon deciding whether
     * your checksum is broken. Get it right here and everything downstream
     * matches the docs. [selfTest] asserts exactly this.
     *
     * (The same trap bites in PowerShell, where [math]::Round(50 * 2.55)
     * also returns 127. Use the same floor-based form there.)
     */
    fun wire(value: Float): Int {
        val clamped = value.coerceIn(MIN, MAX)
        return floor(clamped.toDouble() * 255.0 / 100.0 + 0.5).toInt().coerceIn(0, 255)
    }

    /**
     * Fletcher-8 checksum, MOD 255.
     *
     * Note the 255, not 256. A "% 256" version is what you get for free from
     * byte overflow, which makes this an easy thing to get subtly wrong: it
     * produces identical results for most short frames and then diverges.
     *
     * Returns both sums packed as (s2 shl 8) or s1. They are appended to the
     * frame s2 FIRST, then s1 - which is the opposite of the order you
     * compute them in, and another easy thing to flip.
     */
    fun fletcher8(data: ByteArray, length: Int = data.size): Int {
        var s1 = 0
        var s2 = 0
        for (i in 0 until length) {
            s1 = (s1 + (data[i].toInt() and 0xFF)) % 255
            s2 = (s2 + s1) % 255
        }
        return (s2 shl 8) or s1
    }

    /**
     * Wrap a payload in the FA 00 header and the trailing checksum.
     * This is the only place a frame is assembled.
     */
    fun frame(payload: ByteArray): ByteArray {
        val out = ByteArray(3 + payload.size + 2)
        out[0] = 0xFA.toByte()
        out[1] = 0x00
        out[2] = payload.size.toByte()
        System.arraycopy(payload, 0, out, 3, payload.size)

        // Checksum covers the header and payload: everything except the two
        // checksum bytes we are about to write.
        val ck = fletcher8(out, 3 + payload.size)
        out[3 + payload.size] = (ck ushr 8).toByte()   // s2 first
        out[4 + payload.size] = ck.toByte()            // then s1
        return out
    }

    // -----------------------------------------------------------------------
    // ROW 5: BUILDING MOVE FRAMES
    // -----------------------------------------------------------------------

    /**
     * Build a move frame for any subset of motors.
     *
     * @param values logical 0..100 values keyed by motor bit. Motors absent
     *               from the map are left alone by the board.
     *
     * Prefer ONE frame with several motors over several single-motor frames:
     * the board applies a frame atomically, so a whole pose lands on the same
     * tick instead of rippling across the face.
     */
    fun moveFrame(values: Map<Int, Float>): ByteArray? {
        if (values.isEmpty()) return null

        var mask = 0
        val bytes = ArrayList<Byte>(7)

        // Iterating MOTORS (not the caller's map) is what guarantees
        // MSB-first ordering regardless of what order the caller built it in.
        for (m in MOTORS) {
            val v = values[m.bit] ?: continue
            mask = mask or m.bit
            bytes.add(wire(v).toByte())
        }
        if (mask == 0) return null

        val payload = ByteArray(3 + bytes.size)
        payload[0] = 0x01           // command: set motor positions
        payload[1] = mask.toByte()  // which motors this frame carries
        payload[2] = 0x01           // sub-command, always 1 for a position set
        for (i in bytes.indices) payload[3 + i] = bytes[i]

        return frame(payload)
    }

    /** Convenience wrapper for a single motor. */
    fun moveFrame(motorBit: Int, value: Float): ByteArray? =
        moveFrame(mapOf(motorBit to value))

    /**
     * The power-on frame, hardcoded because it never varies.
     *
     *     FA 00 02 4F 7F 0B CB
     *
     * You can verify it with the code in this file: the payload is 4F 7F, and
     * fletcher8 over FA 00 02 4F 7F gives s2 = 0x0B, s1 = 0xCB. [selfTest]
     * does that check, which is a nice way to prove the checksum is right
     * using a frame we know is correct.
     */
    val POWER_ON: ByteArray = byteArrayOf(
        0xFA.toByte(), 0x00, 0x02, 0x4F, 0x7F, 0x0B, 0xCB.toByte(),
    )

    // -----------------------------------------------------------------------
    // SELF TEST
    // -----------------------------------------------------------------------

    /**
     * Verify this implementation against frames captured from real hardware
     * and published in MABU_MOTOR_GUIDE.md.
     *
     * Called once at startup (see MotorLink.open). It runs in microseconds and
     * turns "my robot does not move" into "my encoder is wrong", which is a
     * much better problem to have. If you port this file to another language,
     * port these checks first.
     *
     * @return null if everything passes, or a description of the first failure.
     */
    fun selfTest(): String? {
        // The encoding trap. If wire(50) is 127 you have the float bug.
        if (wire(50f) != 0x80) return "wire(50) = ${wire(50f)}, expected 0x80 (128)"
        if (wire(25f) != 0x40) return "wire(25) = ${wire(25f)}, expected 0x40 (64)"
        if (wire(0f) != 0x00) return "wire(0) should be 0"
        if (wire(100f) != 0xFF) return "wire(100) should be 255"

        // The power-on frame, rebuilt from its payload.
        val powerOn = frame(byteArrayOf(0x4F, 0x7F))
        if (!powerOn.contentEquals(POWER_ON)) return "power-on frame mismatch: ${hex(powerOn)}"

        // Single-motor frames verified on hardware 2026-05-31.
        // NR = 100 -> head full left.
        val nrLeft = moveFrame(NR, 100f)!!
        if (hex(nrLeft) != "FA 00 04 01 02 01 FF FC 03") return "NR=100 frame: ${hex(nrLeft)}"

        // NR = 0 -> head full right. The checksum is identical to NR=100, which
        // looks like a bug and is not: the value bytes are 0xFF and 0x00, and
        // 255 mod 255 == 0, so both sums land in the same place. A good
        // reminder that a matching checksum is not proof of a correct frame.
        val nrRight = moveFrame(NR, 0f)!!
        if (hex(nrRight) != "FA 00 04 01 02 01 00 FC 03") return "NR=0 frame: ${hex(nrRight)}"

        // ELR = 80 -> eyes right.
        val elr = moveFrame(ELR, 80f)!!
        if (hex(elr) != "FA 00 04 01 10 01 CC F3 DD") return "ELR=80 frame: ${hex(elr)}"

        // Multi-motor ordering: ask in a deliberately scrambled order and
        // check the bytes still come out MSB-first.
        val multi = moveFrame(mapOf(NT to 0f, LDL to 100f, ELR to 50f))!!
        // mask = LDL|ELR|NT = 0x40|0x10|0x01 = 0x51, values FF 80 00
        if (hex(multi) != "FA 00 06 01 51 01 FF 80 00 9E D4") return "multi-motor frame: ${hex(multi)}"

        return null
    }

    /** Uppercase space-separated hex, for logs and the self test. */
    fun hex(bytes: ByteArray): String =
        bytes.joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
}
