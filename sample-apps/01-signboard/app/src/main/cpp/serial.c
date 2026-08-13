// ============================================================================
// serial.c - opening Mabu's motor serial port from native code
//
// INDEX ROW 1. This is the single most important file in the sample, and the
// reason it exists is worth understanding before you copy it.
//
// ----------------------------------------------------------------------------
// WHY THIS IS IN C AND NOT IN KOTLIN
// ----------------------------------------------------------------------------
// The motor board hangs off /dev/ttyS1. Its Unix permissions are wide open
// (crwxrwxrwx), so the obvious thing to write is:
//
//     FileOutputStream("/dev/ttyS1")        // <-- ALWAYS FAILS. Don't.
//
// That throws IOException every time, on every Mabu, and the error message
// does not tell you why. Here is what is actually happening:
//
//   - /dev/ttyS1 is labelled u:object_r:serial_device:s0 by SELinux.
//   - An ordinary app runs as u:r:untrusted_app:s0.
//   - The policy on this device ALLOWS untrusted_app to open, read, write and
//     ioctl a serial_device. It DENIES getattr.
//   - Java's file APIs call stat() before open(), to fill in File metadata.
//     stat() needs getattr. SELinux refuses, so you never reach open().
//
// Native open(2) makes the open syscall directly with no stat() first, hits
// only the permission that is allowed, and succeeds. That is the whole trick.
// Confirmed on hardware: "opened 57600 baud, fd=42", zero AVC denials.
//
// So: about sixty lines of C, and no root, no SELinux patching, no TCP bridge.
//
// ----------------------------------------------------------------------------
// PORTING THIS FILE
// ----------------------------------------------------------------------------
// JNI function names encode the Java package. These are named
// Java_com_getcircuitbent_mabu_signboard_SerialPort_*. If you paste this into
// an app with a different package, you MUST rename them to match or you get
// UnsatisfiedLinkError at runtime (which compiles fine, so you find out on
// the device). Package com.example.foo -> Java_com_example_foo_SerialPort_*.
// ============================================================================

#include <jni.h>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <android/log.h>

#define LOG_TAG "MabuSerial"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)

// The motor board runs at 57600 8N1. This helper exists only so the Kotlin
// side can pass a plain int instead of a termios constant.
static speed_t baud_to_speed(int baud) {
    switch (baud) {
        case   9600: return B9600;
        case  19200: return B19200;
        case  38400: return B38400;
        case  57600: return B57600;   // <- Mabu's motor board
        case 115200: return B115200;
        default:     return 0;
    }
}

/**
 * Open the port and configure it for raw 8N1 at the given baud.
 *
 * Returns a non-negative file descriptor on success, or a NEGATIVE errno on
 * failure (so -13 means EACCES). Kotlin checks for >= 0.
 */
JNIEXPORT jint JNICALL
Java_com_getcircuitbent_mabu_signboard_SerialPort_openTty(
        JNIEnv* env, jclass cls, jstring jpath, jint baud) {

    const char* path = (*env)->GetStringUTFChars(env, jpath, NULL);

    // O_RDWR   - we write commands; read is here so the fd is ready if you
    //            later add telemetry (see the README's "what's next").
    // O_NOCTTY - do NOT let this terminal become the process's controlling
    //            terminal. Without it, a stray SIGHUP on the tty could
    //            signal our whole process.
    int fd = open(path, O_RDWR | O_NOCTTY);

    (*env)->ReleaseStringUTFChars(env, jpath, path);

    if (fd < 0) {
        // The common causes, in the order they actually happen:
        //   EBUSY / EACCES - another app already owns the port. On a freshly
        //                    flashed unit the usual suspect is
        //                    com.catalia.factorymode. Force-stop it.
        //   ENOENT         - not a Mabu, or the motor board is not wired in.
        LOGE("open(%s) failed: %s", "/dev/ttyS1", strerror(errno));
        return -errno;
    }

    speed_t s = baud_to_speed(baud);
    if (s == 0) { close(fd); return -1; }

    struct termios tio;
    if (tcgetattr(fd, &tio) != 0) {
        LOGE("tcgetattr failed: %s", strerror(errno));
        close(fd);
        return -errno;
    }

    cfsetispeed(&tio, s);
    cfsetospeed(&tio, s);

    // Raw 8N1, no flow control.
    //   CS8    - 8 data bits
    //   ~PARENB - no parity      ~CSTOPB - 1 stop bit
    //   ~CRTSCTS - no hardware flow control (the board has no RTS/CTS)
    //   CLOCAL - ignore modem control lines. Without this, an open can block
    //            forever waiting for a carrier signal that never comes.
    //   CREAD  - enable the receiver.
    tio.c_cflag = (tio.c_cflag & ~(CSIZE | PARENB | CSTOPB | CRTSCTS))
                  | CS8 | CLOCAL | CREAD;

    // Zero out input/output/local flags: no echo, no signal generation, no
    // CR/LF translation. This is binary protocol data, and any "helpful"
    // line-discipline processing would corrupt it. In particular, leaving
    // ONLCR on would turn a 0x0A byte in a frame into 0x0D 0x0A.
    tio.c_iflag = 0;
    tio.c_oflag = 0;
    tio.c_lflag = 0;

    tio.c_cc[VMIN]  = 0;
    tio.c_cc[VTIME] = 1;   // 0.1 s read timeout; unused while we only write

    if (tcsetattr(fd, TCSANOW, &tio) != 0) {
        LOGE("tcsetattr failed: %s", strerror(errno));
        close(fd);
        return -errno;
    }

    // Discard anything already sitting in the kernel buffers, so our first
    // frame is not preceded by garbage from whoever had the port before us.
    tcflush(fd, TCIOFLUSH);

    LOGI("opened %s at %d baud, fd=%d", "/dev/ttyS1", baud, fd);
    return fd;
}

/**
 * Write raw bytes. Returns bytes written, or a negative errno.
 *
 * NOTE: this does not loop on partial writes. Motor frames are 7 to 12 bytes
 * and the tty buffer is far larger, so a short write does not happen in
 * practice here. If you adapt this for larger payloads, wrap it in a loop.
 */
JNIEXPORT jint JNICALL
Java_com_getcircuitbent_mabu_signboard_SerialPort_writeBytes(
        JNIEnv* env, jclass cls, jint fd, jbyteArray data, jint off, jint len) {

    if (fd < 0) return -1;

    jbyte* buf = (*env)->GetByteArrayElements(env, data, NULL);
    ssize_t n = write(fd, (char*)buf + off, (size_t)len);
    // JNI_ABORT: we did not modify the buffer, so do not copy it back.
    (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);

    if (n < 0) {
        LOGE("write failed: %s", strerror(errno));
        return -errno;
    }
    return (jint)n;
}

JNIEXPORT void JNICALL
Java_com_getcircuitbent_mabu_signboard_SerialPort_closeTty(
        JNIEnv* env, jclass cls, jint fd) {
    if (fd >= 0) close(fd);
}
