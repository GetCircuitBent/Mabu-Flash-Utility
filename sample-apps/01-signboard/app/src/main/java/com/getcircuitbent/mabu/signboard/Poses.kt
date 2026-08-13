package com.getcircuitbent.mabu.signboard

import com.getcircuitbent.mabu.signboard.MabuProtocol.ELR
import com.getcircuitbent.mabu.signboard.MabuProtocol.EUD
import com.getcircuitbent.mabu.signboard.MabuProtocol.EYELID_CLOSED
import com.getcircuitbent.mabu.signboard.MabuProtocol.EYELID_OPEN
import com.getcircuitbent.mabu.signboard.MabuProtocol.EYELID_WIDE
import com.getcircuitbent.mabu.signboard.MabuProtocol.LDL
import com.getcircuitbent.mabu.signboard.MabuProtocol.LDR
import com.getcircuitbent.mabu.signboard.MabuProtocol.NE
import com.getcircuitbent.mabu.signboard.MabuProtocol.NR
import com.getcircuitbent.mabu.signboard.MabuProtocol.NT

/**
 * ============================================================================
 * INDEX ROW 7 - named poses.
 * ============================================================================
 *
 * A pose is just a map of motor bit to logical value. There is no machinery
 * here at all, which is the point: once you have the motor table, a pose is
 * data.
 *
 * Poses are applied as TARGETS, so the tween eases into them. Pressing
 * "Sleep" glides the eyelids shut over a couple of hundred milliseconds
 * rather than slamming them.
 *
 * ---------------------------------------------------------------------------
 * ADDING YOUR OWN
 * ---------------------------------------------------------------------------
 * 1. Add a `val MY_POSE = pose(...)` below.
 * 2. Add it to [ALL].
 * That is all. The admin screen builds its buttons from [ALL], and the ADB
 * POSE broadcast looks up names in [ALL], so both pick it up automatically.
 */
object Poses {

    data class Pose(val name: String, val values: Map<Int, Float>)

    private fun pose(name: String, vararg pairs: Pair<Int, Float>) =
        Pose(name, mapOf(*pairs))

    /**
     * Everything centred, eyelids at their natural resting position.
     * This is the pose the app lands on at startup.
     */
    val NEUTRAL = pose(
        "Neutral",
        LDL to EYELID_OPEN, LDR to EYELID_OPEN,
        ELR to 50f, EUD to 50f,
        NE to 50f, NR to 50f, NT to 50f,
    )

    /** Eyes wide. Reads as alert or startled; good for a sign that just woke up. */
    val ALERT = pose(
        "Alert",
        LDL to EYELID_WIDE, LDR to EYELID_WIDE,
        ELR to 50f, EUD to 45f,
        NE to 55f, NR to 50f, NT to 50f,
    )

    /**
     * Eyelids shut, head lowered and leaned slightly. Reads as "off" without
     * actually cutting power, so the robot looks asleep rather than dead.
     */
    val SLEEP = pose(
        "Sleep",
        LDL to EYELID_CLOSED, LDR to EYELID_CLOSED,
        ELR to 50f, EUD to 50f,
        NE to 30f, NR to 50f, NT to 58f,
    )

    // Direction poses. Remember while reading these:
    //   ELR: higher = look right.    NR: higher = turn LEFT.
    //   EUD: higher = look DOWN.     NE: higher = head UP.
    // The eye and neck motors for an axis run in OPPOSITE directions, so
    // pointing eyes and head the same way needs opposite-looking numbers.
    // This is the single most confusing thing about the motor table, and it
    // is why the "look" poses below drive both motors explicitly.

    val LOOK_LEFT = pose(
        "Look L",
        ELR to 20f,   // eyes left
        NR to 68f,    // head left (higher = left)
    )

    val LOOK_RIGHT = pose(
        "Look R",
        ELR to 80f,   // eyes right
        NR to 32f,    // head right (lower = right)
    )

    val LOOK_UP = pose(
        "Look Up",
        EUD to 25f,   // eyes up (LOWER value: EUD is inverted)
        NE to 65f,    // head up
    )

    val LOOK_DOWN = pose(
        "Look Dn",
        EUD to 75f,   // eyes down
        NE to 35f,    // head down
    )

    /** Drives the admin buttons and the ADB POSE action. Order is button order. */
    val ALL = listOf(NEUTRAL, ALERT, SLEEP, LOOK_LEFT, LOOK_RIGHT, LOOK_UP, LOOK_DOWN)

    /** Case-insensitive lookup, for the ADB control surface. */
    fun byName(name: String): Pose? =
        ALL.firstOrNull { it.name.equals(name, ignoreCase = true) }
}
