/*
 * TVADB Virtual Mouse
 *
 * A tiny, libc-free Android/Linux helper that registers a relative mouse.
 * It prefers /dev/uhid so the Linux HID subsystem sees the same report
 * descriptor and reports as a physical mouse. If UHID is missing or blocked,
 * it falls back to the existing /dev/uinput path. It runs as the
 * already-authorized ADB shell user and reads a deliberately small text
 * protocol from stdin:
 *
 *   M <dx> <dy>  move
 *   C [button]   click (1 left, 2 right, 4 middle)
 *   D <button>   button down
 *   U <button>   button up
 *   W <amount>   vertical wheel
 *   Q            quit
 *
 * This file uses only Linux syscalls so the resulting binaries are small,
 * static, and do not depend on an Android system image's bionic version.
 */

typedef unsigned char tv_u8;
typedef unsigned short tv_u16;
typedef unsigned int tv_u32;
typedef signed int tv_s32;
typedef signed long tv_slong;
typedef unsigned long tv_ulong;

#if defined(__aarch64__)
#define TV_NR_READ 63
#define TV_NR_WRITE 64
#define TV_NR_OPENAT 56
#define TV_NR_CLOSE 57
#define TV_NR_IOCTL 29
#define TV_NR_EXIT_GROUP 94
static tv_slong tv_syscall4(
    tv_slong number,
    tv_slong first,
    tv_slong second,
    tv_slong third,
    tv_slong fourth
) {
    register tv_slong x8 __asm__("x8") = number;
    register tv_slong x0 __asm__("x0") = first;
    register tv_slong x1 __asm__("x1") = second;
    register tv_slong x2 __asm__("x2") = third;
    register tv_slong x3 __asm__("x3") = fourth;
    __asm__ volatile(
        "svc 0"
        : "+r"(x0)
        : "r"(x8), "r"(x1), "r"(x2), "r"(x3)
        : "memory"
    );
    return x0;
}
#elif defined(__x86_64__)
#define TV_NR_READ 0
#define TV_NR_WRITE 1
#define TV_NR_OPENAT 257
#define TV_NR_CLOSE 3
#define TV_NR_IOCTL 16
#define TV_NR_EXIT_GROUP 231
static tv_slong tv_syscall4(
    tv_slong number,
    tv_slong first,
    tv_slong second,
    tv_slong third,
    tv_slong fourth
) {
    register tv_slong r10 __asm__("r10") = fourth;
    tv_slong result;
    __asm__ volatile(
        "syscall"
        : "=a"(result)
        : "a"(number), "D"(first), "S"(second), "d"(third), "r"(r10)
        : "rcx", "r11", "memory"
    );
    return result;
}
#elif defined(__arm__)
#define TV_NR_READ 3
#define TV_NR_WRITE 4
#define TV_NR_OPENAT 322
#define TV_NR_CLOSE 6
#define TV_NR_IOCTL 54
#define TV_NR_EXIT_GROUP 248
static tv_slong tv_syscall4(
    tv_slong number,
    tv_slong first,
    tv_slong second,
    tv_slong third,
    tv_slong fourth
) {
    register tv_slong r7 __asm__("r7") = number;
    register tv_slong r0 __asm__("r0") = first;
    register tv_slong r1 __asm__("r1") = second;
    register tv_slong r2 __asm__("r2") = third;
    register tv_slong r3 __asm__("r3") = fourth;
    __asm__ volatile(
        "svc 0"
        : "+r"(r0)
        : "r"(r7), "r"(r1), "r"(r2), "r"(r3)
        : "memory"
    );
    return r0;
}
#elif defined(__i386__)
#define TV_NR_READ 3
#define TV_NR_WRITE 4
#define TV_NR_OPENAT 295
#define TV_NR_CLOSE 6
#define TV_NR_IOCTL 54
#define TV_NR_EXIT_GROUP 252
static tv_slong tv_syscall4(
    tv_slong number,
    tv_slong first,
    tv_slong second,
    tv_slong third,
    tv_slong fourth
) {
    tv_slong result;
    __asm__ volatile(
        "int $0x80"
        : "=a"(result)
        : "a"(number), "b"(first), "c"(second), "d"(third), "S"(fourth)
        : "memory"
    );
    return result;
}
#else
#error Unsupported Android architecture
#endif

#define TV_AT_FDCWD (-100)
#define TV_O_WRONLY 1
#define TV_O_RDWR 2
#define TV_O_NONBLOCK 04000

#define TV_EV_SYN 0
#define TV_EV_KEY 1
#define TV_EV_REL 2
#define TV_SYN_REPORT 0
#define TV_REL_X 0
#define TV_REL_Y 1
#define TV_REL_WHEEL 8
#define TV_BTN_LEFT 272
#define TV_BTN_RIGHT 273
#define TV_BTN_MIDDLE 274
#define TV_BUS_USB 0x03
#define TV_BUS_VIRTUAL 0x06

#define TV_UHID_CREATE2 11
#define TV_UHID_INPUT2 12

#define TV_UI_DEV_CREATE 0x5501UL
#define TV_UI_DEV_DESTROY 0x5502UL
#define TV_UI_DEV_SETUP 0x405c5503UL
#define TV_UI_SET_EVBIT 0x40045564UL
#define TV_UI_SET_KEYBIT 0x40045565UL
#define TV_UI_SET_RELBIT 0x40045566UL

struct tv_input_id {
    tv_u16 bustype;
    tv_u16 vendor;
    tv_u16 product;
    tv_u16 version;
};

struct tv_uinput_setup {
    struct tv_input_id id;
    char name[80];
    tv_u32 ff_effects_max;
};

struct tv_uinput_user_dev {
    char name[80];
    struct tv_input_id id;
    tv_u32 ff_effects_max;
    tv_s32 absmax[64];
    tv_s32 absmin[64];
    tv_s32 absfuzz[64];
    tv_s32 absflat[64];
};

struct tv_timeval {
    tv_slong seconds;
    tv_slong microseconds;
};

struct tv_input_event {
    struct tv_timeval time;
    tv_u16 type;
    tv_u16 code;
    tv_s32 value;
};

static tv_slong tv_read(int descriptor, void *buffer, tv_ulong count) {
    return tv_syscall4(
        TV_NR_READ,
        descriptor,
        (tv_slong)buffer,
        (tv_slong)count,
        0
    );
}

static tv_slong tv_write(int descriptor, const void *buffer, tv_ulong count) {
    return tv_syscall4(
        TV_NR_WRITE,
        descriptor,
        (tv_slong)buffer,
        (tv_slong)count,
        0
    );
}

static int tv_open_write(const char *path) {
    return (int)tv_syscall4(
        TV_NR_OPENAT,
        TV_AT_FDCWD,
        (tv_slong)path,
        TV_O_WRONLY | TV_O_NONBLOCK,
        0
    );
}

static int tv_open_read_write(const char *path) {
    return (int)tv_syscall4(
        TV_NR_OPENAT,
        TV_AT_FDCWD,
        (tv_slong)path,
        TV_O_RDWR | TV_O_NONBLOCK,
        0
    );
}

static tv_slong tv_ioctl(int descriptor, tv_ulong request, tv_slong value) {
    return tv_syscall4(
        TV_NR_IOCTL,
        descriptor,
        (tv_slong)request,
        value,
        0
    );
}

static void tv_close(int descriptor) {
    (void)tv_syscall4(TV_NR_CLOSE, descriptor, 0, 0, 0);
}

__attribute__((noreturn))
static void tv_exit(int status) {
    (void)tv_syscall4(TV_NR_EXIT_GROUP, status, 0, 0, 0);
    for (;;) {}
}

static tv_ulong tv_length(const char *text) {
    tv_ulong length = 0;
    while (text[length] != '\0') {
        length++;
    }
    return length;
}

static void tv_status(const char *text) {
    (void)tv_write(1, text, tv_length(text));
}

static void tv_error(const char *text) {
    (void)tv_write(2, text, tv_length(text));
}

static void tv_zero(void *target, tv_ulong count) {
    tv_u8 *bytes = (tv_u8 *)target;
    tv_ulong index;
    for (index = 0; index < count; index++) {
        bytes[index] = 0;
    }
}

static void tv_copy_name(char *target, const char *source, tv_ulong capacity) {
    tv_ulong index = 0;
    while (index + 1 < capacity && source[index] != '\0') {
        target[index] = source[index];
        index++;
    }
    target[index] = '\0';
}

static void tv_store_u16(tv_u8 *target, tv_u16 value) {
    target[0] = (tv_u8)(value & 0xff);
    target[1] = (tv_u8)((value >> 8) & 0xff);
}

static void tv_store_u32(tv_u8 *target, tv_u32 value) {
    target[0] = (tv_u8)(value & 0xff);
    target[1] = (tv_u8)((value >> 8) & 0xff);
    target[2] = (tv_u8)((value >> 16) & 0xff);
    target[3] = (tv_u8)((value >> 24) & 0xff);
}

static int tv_parse_integer(
    const char *line,
    int length,
    int *cursor,
    tv_s32 *result
) {
    tv_s32 value = 0;
    int sign = 1;
    int saw_digit = 0;

    while (*cursor < length && line[*cursor] == ' ') {
        (*cursor)++;
    }
    if (*cursor < length && line[*cursor] == '-') {
        sign = -1;
        (*cursor)++;
    } else if (*cursor < length && line[*cursor] == '+') {
        (*cursor)++;
    }
    while (*cursor < length) {
        char character = line[*cursor];
        if (character < '0' || character > '9') {
            break;
        }
        saw_digit = 1;
        value = value * 10 + (character - '0');
        (*cursor)++;
    }
    if (!saw_digit) {
        return 0;
    }
    *result = value * sign;
    return 1;
}

static int tv_emit(int descriptor, tv_u16 type, tv_u16 code, tv_s32 value) {
    struct tv_input_event event;
    tv_zero(&event, sizeof(event));
    event.type = type;
    event.code = code;
    event.value = value;
    return tv_write(descriptor, &event, sizeof(event)) == sizeof(event);
}

static int tv_sync(int descriptor) {
    return tv_emit(descriptor, TV_EV_SYN, TV_SYN_REPORT, 0);
}

static int tv_uinput_move(int descriptor, tv_s32 delta_x, tv_s32 delta_y) {
    if (delta_x != 0 && !tv_emit(descriptor, TV_EV_REL, TV_REL_X, delta_x)) {
        return 0;
    }
    if (delta_y != 0 && !tv_emit(descriptor, TV_EV_REL, TV_REL_Y, delta_y)) {
        return 0;
    }
    return tv_sync(descriptor);
}

static tv_u16 tv_uinput_button_code(tv_u8 button) {
    if (button == 2) {
        return TV_BTN_RIGHT;
    }
    if (button == 4) {
        return TV_BTN_MIDDLE;
    }
    return TV_BTN_LEFT;
}

static int tv_uinput_set_button(
    int descriptor,
    tv_u8 button,
    int pressed
) {
    return tv_emit(
            descriptor,
            TV_EV_KEY,
            tv_uinput_button_code(button),
            pressed ? 1 : 0
        )
        && tv_sync(descriptor);
}

static int tv_uinput_click(int descriptor, tv_u8 button) {
    return tv_uinput_set_button(descriptor, button, 1)
        && tv_uinput_set_button(descriptor, button, 0);
}

static int tv_uinput_wheel(int descriptor, tv_s32 amount) {
    return tv_emit(descriptor, TV_EV_REL, TV_REL_WHEEL, amount)
        && tv_sync(descriptor);
}

static int tv_configure_uinput_mouse(int descriptor) {
    struct tv_uinput_setup setup;
    struct tv_uinput_user_dev legacy;
    const char *name = "TVADB Virtual Mouse";

    if (tv_ioctl(descriptor, TV_UI_SET_EVBIT, TV_EV_KEY) < 0
        || tv_ioctl(descriptor, TV_UI_SET_EVBIT, TV_EV_REL) < 0
        || tv_ioctl(descriptor, TV_UI_SET_KEYBIT, TV_BTN_LEFT) < 0
        || tv_ioctl(descriptor, TV_UI_SET_KEYBIT, TV_BTN_RIGHT) < 0
        || tv_ioctl(descriptor, TV_UI_SET_KEYBIT, TV_BTN_MIDDLE) < 0
        || tv_ioctl(descriptor, TV_UI_SET_RELBIT, TV_REL_X) < 0
        || tv_ioctl(descriptor, TV_UI_SET_RELBIT, TV_REL_Y) < 0
        || tv_ioctl(descriptor, TV_UI_SET_RELBIT, TV_REL_WHEEL) < 0) {
        return 0;
    }

    tv_zero(&setup, sizeof(setup));
    setup.id.bustype = TV_BUS_USB;
    setup.id.vendor = 0x1209;
    setup.id.product = 0x3729;
    setup.id.version = 1;
    tv_copy_name(setup.name, name, sizeof(setup.name));

    if (tv_ioctl(
            descriptor,
            TV_UI_DEV_SETUP,
            (tv_slong)&setup
        ) < 0) {
        /*
         * UI_DEV_SETUP was added in Linux 4.5. Older Android TV kernels use
         * the legacy uinput_user_dev write before UI_DEV_CREATE.
         */
        tv_zero(&legacy, sizeof(legacy));
        tv_copy_name(legacy.name, name, sizeof(legacy.name));
        legacy.id = setup.id;
        if (tv_write(descriptor, &legacy, sizeof(legacy)) != sizeof(legacy)) {
            return 0;
        }
    }

    return tv_ioctl(descriptor, TV_UI_DEV_CREATE, 0) >= 0;
}

/*
 * Standard relative mouse HID descriptor:
 *   byte 0: buttons 1-3
 *   byte 1: relative X (-127...127)
 *   byte 2: relative Y (-127...127)
 *   byte 3: vertical wheel (-127...127)
 */
static const tv_u8 tv_hid_mouse_report_descriptor[] = {
    0x05, 0x01,       /* Usage Page (Generic Desktop) */
    0x09, 0x02,       /* Usage (Mouse) */
    0xa1, 0x01,       /* Collection (Application) */
    0x09, 0x01,       /* Usage (Pointer) */
    0xa1, 0x00,       /* Collection (Physical) */
    0x05, 0x09,       /* Usage Page (Button) */
    0x19, 0x01,       /* Usage Minimum (Button 1) */
    0x29, 0x03,       /* Usage Maximum (Button 3) */
    0x15, 0x00,       /* Logical Minimum (0) */
    0x25, 0x01,       /* Logical Maximum (1) */
    0x95, 0x03,       /* Report Count (3) */
    0x75, 0x01,       /* Report Size (1) */
    0x81, 0x02,       /* Input (Data, Variable, Absolute) */
    0x95, 0x01,       /* Report Count (1) */
    0x75, 0x05,       /* Report Size (5) */
    0x81, 0x01,       /* Input (Constant) */
    0x05, 0x01,       /* Usage Page (Generic Desktop) */
    0x09, 0x30,       /* Usage (X) */
    0x09, 0x31,       /* Usage (Y) */
    0x09, 0x38,       /* Usage (Wheel) */
    0x15, 0x81,       /* Logical Minimum (-127) */
    0x25, 0x7f,       /* Logical Maximum (127) */
    0x75, 0x08,       /* Report Size (8) */
    0x95, 0x03,       /* Report Count (3) */
    0x81, 0x06,       /* Input (Data, Variable, Relative) */
    0xc0,             /* End Collection */
    0xc0              /* End Collection */
};

static int tv_configure_uhid_mouse(int descriptor) {
    /*
     * Linux include/uapi/linux/uhid.h:
     * struct uhid_event {
     *   __u32 type;
     *   union { struct uhid_create2_req create2; ... } u;
     * } __attribute__((packed));
     *
     * The kernel accepts the event truncated immediately after rd_data.
     */
    tv_u8 event[280 + sizeof(tv_hid_mouse_report_descriptor)];
    const char *name = "TVADB Virtual Mouse";
    const char *physical_port = "tvadb:virtual-mouse";
    tv_ulong index;

    tv_zero(event, sizeof(event));
    tv_store_u32(event, TV_UHID_CREATE2);
    for (index = 0; index < 127 && name[index] != '\0'; index++) {
        event[4 + index] = (tv_u8)name[index];
    }
    for (index = 0; index < 63 && physical_port[index] != '\0'; index++) {
        event[4 + 128 + index] = (tv_u8)physical_port[index];
    }
    tv_store_u16(event + 260, sizeof(tv_hid_mouse_report_descriptor));
    /*
     * Advertise the UHID device as USB, matching a physical mouse. Some TV
     * and emulator frameworks deliberately suppress the pointer sprite for
     * BUS_VIRTUAL devices even though InputReader still dispatches their
     * hover and button events.
     */
    tv_store_u16(event + 262, TV_BUS_USB);
    tv_store_u32(event + 264, 0x1209);
    tv_store_u32(event + 268, 0x3729);
    tv_store_u32(event + 272, 1);
    tv_store_u32(event + 276, 0);
    for (index = 0; index < sizeof(tv_hid_mouse_report_descriptor); index++) {
        event[280 + index] = tv_hid_mouse_report_descriptor[index];
    }
    return tv_write(descriptor, event, sizeof(event)) == sizeof(event);
}

static int tv_uhid_report(
    int descriptor,
    tv_u8 buttons,
    tv_s32 delta_x,
    tv_s32 delta_y,
    tv_s32 wheel
) {
    tv_u8 event[10];
    tv_zero(event, sizeof(event));
    tv_store_u32(event, TV_UHID_INPUT2);
    tv_store_u16(event + 4, 4);
    event[6] = buttons;
    event[7] = (tv_u8)delta_x;
    event[8] = (tv_u8)delta_y;
    event[9] = (tv_u8)wheel;
    return tv_write(descriptor, event, sizeof(event)) == sizeof(event);
}

static tv_s32 tv_hid_chunk(tv_s32 value) {
    if (value > 127) {
        return 127;
    }
    if (value < -127) {
        return -127;
    }
    return value;
}

static int tv_uhid_move(
    int descriptor,
    tv_u8 buttons,
    tv_s32 delta_x,
    tv_s32 delta_y
) {
    do {
        tv_s32 step_x = tv_hid_chunk(delta_x);
        tv_s32 step_y = tv_hid_chunk(delta_y);
        if (!tv_uhid_report(descriptor, buttons, step_x, step_y, 0)) {
            return 0;
        }
        delta_x -= step_x;
        delta_y -= step_y;
    } while (delta_x != 0 || delta_y != 0);
    return 1;
}

static int tv_uhid_set_button(
    int descriptor,
    tv_u8 *buttons,
    tv_u8 button,
    int pressed
) {
    if (pressed) {
        *buttons |= button;
    } else {
        *buttons &= (tv_u8)~button;
    }
    return tv_uhid_report(descriptor, *buttons, 0, 0, 0);
}

static int tv_uhid_click(
    int descriptor,
    tv_u8 *buttons,
    tv_u8 button
) {
    return tv_uhid_set_button(descriptor, buttons, button, 1)
        && tv_uhid_set_button(descriptor, buttons, button, 0);
}

static int tv_uhid_wheel(
    int descriptor,
    tv_u8 buttons,
    tv_s32 amount
) {
    do {
        tv_s32 step = tv_hid_chunk(amount);
        if (!tv_uhid_report(descriptor, buttons, 0, 0, step)) {
            return 0;
        }
        amount -= step;
    } while (amount != 0);
    return 1;
}

#define TV_MOUSE_BACKEND_UINPUT 1
#define TV_MOUSE_BACKEND_UHID 2

static tv_u8 tv_button_mask(tv_s32 value) {
    if (value == 2) {
        return 2;
    }
    if (value == 4) {
        return 4;
    }
    return 1;
}

static int tv_handle_line(
    int descriptor,
    int backend,
    tv_u8 *buttons,
    const char *line,
    int length
) {
    int cursor = 1;
    tv_s32 first = 0;
    tv_s32 second = 0;

    if (length <= 0) {
        return 1;
    }
    if (line[0] == 'Q') {
        return 0;
    }
    if (line[0] == 'C') {
        tv_u8 button = 1;
        if (tv_parse_integer(line, length, &cursor, &first)) {
            button = tv_button_mask(first);
        }
        if (backend == TV_MOUSE_BACKEND_UHID) {
            (void)tv_uhid_click(descriptor, buttons, button);
        } else {
            (void)tv_uinput_click(descriptor, button);
        }
        return 1;
    }
    if ((line[0] == 'D' || line[0] == 'U')
        && tv_parse_integer(line, length, &cursor, &first)) {
        tv_u8 button = tv_button_mask(first);
        int pressed = line[0] == 'D';
        if (backend == TV_MOUSE_BACKEND_UHID) {
            (void)tv_uhid_set_button(
                descriptor,
                buttons,
                button,
                pressed
            );
        } else {
            if (pressed) {
                *buttons |= button;
            } else {
                *buttons &= (tv_u8)~button;
            }
            (void)tv_uinput_set_button(
                descriptor,
                button,
                pressed
            );
        }
        return 1;
    }
    if (line[0] == 'M'
        && tv_parse_integer(line, length, &cursor, &first)
        && tv_parse_integer(line, length, &cursor, &second)) {
        if (backend == TV_MOUSE_BACKEND_UHID) {
            (void)tv_uhid_move(
                descriptor,
                *buttons,
                first,
                second
            );
        } else {
            (void)tv_uinput_move(descriptor, first, second);
        }
        return 1;
    }
    if (line[0] == 'W'
        && tv_parse_integer(line, length, &cursor, &first)) {
        if (backend == TV_MOUSE_BACKEND_UHID) {
            (void)tv_uhid_wheel(descriptor, *buttons, first);
        } else {
            (void)tv_uinput_wheel(descriptor, first);
        }
    }
    return 1;
}

__attribute__((noreturn))
void _start(void) {
    char input[256];
    char line[128];
    int line_length = 0;
    tv_u8 buttons = 0;
    int backend = TV_MOUSE_BACKEND_UHID;
    int descriptor = tv_open_read_write("/dev/uhid");

    if (descriptor < 0 || !tv_configure_uhid_mouse(descriptor)) {
        if (descriptor >= 0) {
            tv_close(descriptor);
        }
        backend = TV_MOUSE_BACKEND_UINPUT;
        descriptor = tv_open_write("/dev/uinput");
        if (descriptor < 0) {
            tv_error("TVADB_MOUSE_DEVICE_OPEN_FAILED\n");
            tv_exit(20);
        }
        if (!tv_configure_uinput_mouse(descriptor)) {
            tv_error("TVADB_UINPUT_CONFIGURE_FAILED\n");
            tv_close(descriptor);
            tv_exit(21);
        }
        tv_status("TVADB_UINPUT_READY\n");
    } else {
        tv_status("TVADB_UHID_READY\n");
    }
    for (;;) {
        tv_slong count = tv_read(0, input, sizeof(input));
        int index;
        if (count <= 0) {
            break;
        }
        for (index = 0; index < count; index++) {
            char character = input[index];
            if (character == '\n' || character == '\r') {
                if (line_length > 0
                    && !tv_handle_line(
                        descriptor,
                        backend,
                        &buttons,
                        line,
                        line_length
                    )) {
                    if (backend == TV_MOUSE_BACKEND_UINPUT) {
                        (void)tv_ioctl(descriptor, TV_UI_DEV_DESTROY, 0);
                    }
                    tv_close(descriptor);
                    tv_exit(0);
                }
                line_length = 0;
            } else if (line_length < (int)sizeof(line) - 1) {
                line[line_length++] = character;
            }
        }
    }

    if (backend == TV_MOUSE_BACKEND_UINPUT) {
        (void)tv_ioctl(descriptor, TV_UI_DEV_DESTROY, 0);
    }
    tv_close(descriptor);
    tv_exit(0);
}
