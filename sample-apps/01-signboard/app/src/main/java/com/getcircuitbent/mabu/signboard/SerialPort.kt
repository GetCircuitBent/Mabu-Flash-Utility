package com.getcircuitbent.mabu.signboard

/**
 * INDEX ROW 1 - the Kotlin side of the native serial shim.
 *
 * This is deliberately as thin as it can be: three calls that map 1:1 onto
 * open(2), write(2) and close(2) in `cpp/serial.c`. All the interesting
 * commentary lives in that file - read it first if you are wondering why
 * this is not just a FileOutputStream.
 *
 * The short version: Java file I/O calls stat() before open(), SELinux on
 * this device denies getattr on /dev/ttyS1, so Java always fails and native
 * open() always works.
 */
object SerialPort {

    init {
        // Matches add_library(mabusignboard ...) in cpp/CMakeLists.txt.
        System.loadLibrary("mabusignboard")
    }

    /**
     * @return a non-negative file descriptor, or a negative errno.
     *         -13 (EACCES) or -16 (EBUSY) usually means another app owns
     *         the port.
     */
    @JvmStatic
    external fun openTty(path: String, baud: Int): Int

    /** @return bytes written, or a negative errno. */
    @JvmStatic
    external fun writeBytes(fd: Int, data: ByteArray, off: Int, len: Int): Int

    @JvmStatic
    external fun closeTty(fd: Int)
}
