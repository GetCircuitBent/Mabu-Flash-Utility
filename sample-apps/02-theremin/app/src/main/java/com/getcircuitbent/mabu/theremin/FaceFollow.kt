package com.getcircuitbent.mabu.theremin

/**
 * ============================================================================
 * INDEX ROW 14 - the robot watches the player.
 * ============================================================================
 *
 * Face box in, eye and neck targets out. Deliberately the simplest thing that
 * looks alive: no cross-frame tracker, no multi-face arbitration, no pose
 * mirroring. This app's subject is audio, and an elaborate tracker here would
 * bury it. App 1's IdleScene supplies the blinking unchanged.
 *
 * ---------------------------------------------------------------------------
 * HOW IT COMPOSES WITH IDLE, WITHOUT EITHER KNOWING ABOUT THE OTHER
 * ---------------------------------------------------------------------------
 * MainActivity ticks IdleScene first, then this. Both write TARGETS, so the
 * later writer wins for any motor they both touch:
 *
 *   face visible  -> this overwrites the idle sweep. Robot watches you.
 *   no face       -> this writes nothing. The idle sweep shows through.
 *   either way    -> blinks are a GESTURE, and gestures claim their motors,
 *                    so the eyelids are untouched by both.
 *
 * That is the whole arbitration: ordering plus the gesture player's claim
 * mask. No mode flags, no state machine, nothing to get out of sync.
 *
 * ---------------------------------------------------------------------------
 * THE TWO SIGN TRAPS
 * ---------------------------------------------------------------------------
 * 1. THE CAMERA IS MIRRORED relative to the robot's point of view. When you
 *    move right, your face moves LEFT in the frame.
 * 2. THE EYE AND NECK MOTORS RUN OPPOSITE WAYS on each axis. ELR higher is
 *    eyes right; NR higher is head LEFT. EUD higher is eyes down; NE higher is
 *    head UP.
 *
 * Get either wrong and the robot looks determinedly away from you, which is
 * funny once. Both are folded into the signs below; change them only with the
 * robot in front of you.
 */
class FaceFollow(
    private val tween: MotorTween,
    private val player: GesturePlayer,
) {

    /**
     * Camera mounting compensation, in normalised units.
     *
     * The camera is in the CHEST tablet, angled up, well below the eye axis,
     * so a person standing at a normal distance appears high in the frame.
     * Without this the robot spends its life looking at the ceiling.
     *
     * This is a PER-UNIT calibration. Slide it until the robot looks you in
     * the eye, and expect a different value on a different Mabu.
     */
    @Volatile var yOffset = -0.30f
    @Volatile var xOffset = 0f

    /** Scales face movement to motor travel. Higher is twitchier. */
    @Volatile var gain = 1.3f

    /** How far the neck is allowed to move, either side of centre. */
    @Volatile var neckRange = 18f

    /** How far the eyes are allowed to move, either side of centre. */
    @Volatile var eyeRange = 30f

    @Volatile var enabled = true

    /**
     * @param faceBox normalised [x0,y0,x1,y1,...] or null when no face
     */
    fun tick(faceBox: FloatArray?) {
        if (!enabled || faceBox == null) return

        // Centre of the face, in -1..1 with 0 at frame centre.
        val cx = ((faceBox[0] + faceBox[2]) / 2f) * 2f - 1f
        val cy = ((faceBox[1] + faceBox[3]) / 2f) * 2f - 1f

        val ax = ((cx + xOffset) * gain).coerceIn(-1f, 1f)
        val ay = ((cy + yOffset) * gain).coerceIn(-1f, 1f)

        val claimed = player.claimedMotors

        // Horizontal. Camera mirroring means a face to the frame's right is a
        // person to the robot's left, hence the negation on the eyes.
        if (claimed and MabuProtocol.ELR == 0) {
            tween.setTarget(MabuProtocol.ELR, 50f - ax * eyeRange)
        }
        if (claimed and MabuProtocol.NR == 0) {
            // NR higher = head left, and we want the head to go the same way
            // as the eyes, so this sign is the OPPOSITE of the ELR line above.
            tween.setTarget(MabuProtocol.NR, 50f + ax * neckRange)
        }

        // Vertical. EUD is inverted (higher = looking down), so a face high in
        // frame (negative ay) needs a LOWER EUD.
        if (claimed and MabuProtocol.EUD == 0) {
            tween.setTarget(MabuProtocol.EUD, 50f + ay * eyeRange)
        }
        if (claimed and MabuProtocol.NE == 0) {
            // NE higher = head up, so this is the opposite sign again.
            tween.setTarget(MabuProtocol.NE, 50f - ay * neckRange)
        }
    }
}
