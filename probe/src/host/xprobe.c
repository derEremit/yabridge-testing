#define _POSIX_C_SOURCE 200809L

#include "host.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <X11/extensions/XTest.h>

static int last_x_error;
static const int intermediate_x = 19;
static const int intermediate_y = 23;
static const int container_x = 37;
static const int container_y = 41;

static int capture_x_error(Display *display, XErrorEvent *event) {
    (void)display;
    last_x_error = event->error_code;
    return 0;
}

static bool x11_sync(probe_host_t *host, const char *operation, char *error, size_t size) {
    last_x_error = 0;
    XSync(host->display, False);
    if (last_x_error != 0) {
        char text[128];
        XGetErrorText(host->display, last_x_error, text, sizeof(text));
        snprintf(error, size, "%s failed: X11 error %d (%s)", operation, last_x_error, text);
        return false;
    }
    return true;
}

static int64_t monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

bool probe_x11_init(probe_host_t *host, char *error, size_t error_size) {
    int event_base;
    int error_base;
    int major;
    int minor;
    host->display = XOpenDisplay(NULL);
    if (host->display == NULL) {
        snprintf(error, error_size, "XOpenDisplay failed");
        return false;
    }
    XSetErrorHandler(capture_x_error);
    host->root = DefaultRootWindow(host->display);
    host->xtest_available = XTestQueryExtension(
        host->display, &event_base, &error_base, &major, &minor
    ) != 0;
    if (!host->xtest_available) {
        snprintf(error, error_size, "XTEST extension is unavailable");
        probe_x11_destroy(host);
        return false;
    }
    return true;
}

void probe_x11_destroy(probe_host_t *host) {
    if (host->display == NULL) {
        return;
    }
    if (host->outer != None) {
        XDestroyWindow(host->display, host->outer);
    } else if (host->container != None && host->container != host->gui) {
        XDestroyWindow(host->display, host->container);
    } else if (host->gui != None && host->no_plugin) {
        XDestroyWindow(host->display, host->gui);
    }
    XSync(host->display, False);
    XCloseDisplay(host->display);
    host->display = NULL;
    host->outer = None;
    host->intermediate = None;
    host->container = None;
    host->clap_parent = None;
    host->wrapper = None;
    host->wine_window = None;
    host->gui = None;
}

static bool wait_for_configure(
    probe_host_t *host,
    Window window,
    bool synthetic,
    char *error,
    size_t error_size
) {
    int64_t deadline = monotonic_milliseconds() + 2000;
    for (;;) {
        while (XPending(host->display) > 0) {
            XEvent event;
            XNextEvent(host->display, &event);
            if (event.type == ConfigureNotify && event.xconfigure.window == window &&
                (!synthetic || event.xconfigure.send_event)) {
                host->configure_observed = true;
                host->synthetic_send_event = event.xconfigure.send_event;
                host->configure_event_x = event.xconfigure.x;
                host->configure_event_y = event.xconfigure.y;
                return x11_sync(host, "observing ConfigureNotify", error, error_size);
            }
        }
        int64_t now = monotonic_milliseconds();
        if (now < 0 || now >= deadline) {
            snprintf(
                error,
                error_size,
                "%s ConfigureNotify timed out after 2 seconds",
                synthetic ? "synthetic" : "matching"
            );
            return false;
        }
        struct pollfd descriptor = {
            .fd = ConnectionNumber(host->display),
            .events = POLLIN,
            .revents = 0,
        };
        if (poll(&descriptor, 1, (int)(deadline - now)) < 0 && errno != EINTR) {
            snprintf(error, error_size, "polling ConfigureNotify failed: %s", strerror(errno));
            return false;
        }
    }
}

static bool wait_for_resize_convergence(
    probe_host_t *host,
    unsigned int expected_width,
    unsigned int expected_height,
    char *error,
    size_t error_size
) {
    int64_t deadline = monotonic_milliseconds() + 2000;
    for (;;) {
        while (XPending(host->display) > 0) {
            XEvent event;
            XNextEvent(host->display, &event);
            if (event.type == ConfigureNotify && event.xconfigure.window == host->gui &&
                event.xconfigure.width == (int)expected_width &&
                event.xconfigure.height == (int)expected_height) {
                int x;
                int y;
                unsigned int width;
                unsigned int height;
                if (!probe_x11_geometry(
                        host, &x, &y, &width, &height, error, error_size
                    )) {
                    return false;
                }
                if (width == expected_width && height == expected_height) {
                    host->configure_observed = true;
                    host->synthetic_send_event = event.xconfigure.send_event;
                    host->configure_event_x = event.xconfigure.x;
                    host->configure_event_y = event.xconfigure.y;
                    return true;
                }
            }
        }
        int64_t now = monotonic_milliseconds();
        if (now < 0 || now >= deadline) {
            snprintf(
                error,
                error_size,
                "accepted GUI size %ux%u did not converge after 2 seconds",
                expected_width,
                expected_height
            );
            return false;
        }
        struct pollfd descriptor = {
            .fd = ConnectionNumber(host->display),
            .events = POLLIN,
            .revents = 0,
        };
        if (poll(&descriptor, 1, (int)(deadline - now)) < 0 && errno != EINTR) {
            snprintf(error, error_size, "polling GUI resize failed: %s", strerror(errno));
            return false;
        }
    }
}

static void observe_ready_resize(
    probe_host_t *host,
    unsigned int expected_width,
    unsigned int expected_height
) {
    while (XPending(host->display) > 0) {
        XEvent event;
        XNextEvent(host->display, &event);
        if (event.type == ConfigureNotify && event.xconfigure.window == host->gui &&
            event.xconfigure.width == (int)expected_width &&
            event.xconfigure.height == (int)expected_height) {
            host->configure_observed = true;
            host->synthetic_send_event = event.xconfigure.send_event;
            host->configure_event_x = event.xconfigure.x;
            host->configure_event_y = event.xconfigure.y;
        }
    }
}

bool probe_x11_wait_mapped(
    probe_host_t *host,
    Window window,
    char *error,
    size_t error_size
) {
    int64_t deadline = monotonic_milliseconds() + 2000;
    if (deadline < 0) {
        snprintf(error, error_size, "clock_gettime failed: %s", strerror(errno));
        return false;
    }
    for (;;) {
        XWindowAttributes attributes;
        while (XPending(host->display) > 0) {
            XEvent event;
            XNextEvent(host->display, &event);
            if (event.type == MapNotify && event.xmap.window == window) {
                return x11_sync(host, "mapping window", error, error_size);
            }
        }
        if (XGetWindowAttributes(host->display, window, &attributes) == 0) {
            snprintf(error, error_size, "XGetWindowAttributes failed for window %lu", window);
            return false;
        }
        if (attributes.map_state == IsViewable) {
            return x11_sync(host, "mapping window", error, error_size);
        }
        int64_t now = monotonic_milliseconds();
        if (now < 0 || now >= deadline) {
            snprintf(error, error_size, "MapNotify timed out after 2 seconds");
            return false;
        }
        struct pollfd descriptor = {
            .fd = ConnectionNumber(host->display),
            .events = POLLIN,
            .revents = 0,
        };
        int timeout = (int)(deadline - now);
        if (poll(&descriptor, 1, timeout) < 0 && errno != EINTR) {
            snprintf(error, error_size, "polling X11 events failed: %s", strerror(errno));
            return false;
        }
    }
}

bool probe_x11_open(probe_host_t *host, char *error, size_t error_size) {
    Window parent = host->root;
    if (host->opened) {
        snprintf(error, error_size, "GUI is already open");
        return false;
    }
    if (host->hierarchy != PROBE_HIERARCHY_FLAT) {
        host->outer = XCreateSimpleWindow(
            host->display, host->root, 0, 0, 376, 264, 0, 0, 0x101010
        );
        host->intermediate = XCreateSimpleWindow(
            host->display,
            host->outer,
            intermediate_x,
            intermediate_y,
            357,
            241,
            0,
            0,
            0x181818
        );
        host->container = XCreateSimpleWindow(
            host->display,
            host->intermediate,
            container_x,
            container_y,
            320,
            200,
            0,
            0,
            0x202020
        );
        if (host->outer == None || host->intermediate == None || host->container == None) {
            snprintf(error, error_size, "XCreateSimpleWindow failed for nested hierarchy");
            return false;
        }
        XSelectInput(host->display, host->outer, StructureNotifyMask);
        XSelectInput(host->display, host->intermediate, StructureNotifyMask);
        XSelectInput(host->display, host->container, StructureNotifyMask);
        XMapWindow(host->display, host->outer);
        if (!probe_x11_wait_mapped(host, host->outer, error, error_size)) {
            return false;
        }
        XMapWindow(host->display, host->intermediate);
        if (!probe_x11_wait_mapped(host, host->intermediate, error, error_size)) {
            return false;
        }
        XMapWindow(host->display, host->container);
        if (!probe_x11_wait_mapped(host, host->container, error, error_size)) {
            return false;
        }
        parent = host->container;
    } else if (!host->no_plugin) {
        host->container = XCreateSimpleWindow(
            host->display, host->root, 0, 0, 320, 200, 0, 0, 0x202020
        );
        if (host->container == None) {
            snprintf(error, error_size, "XCreateSimpleWindow failed for container");
            return false;
        }
        XSelectInput(host->display, host->container, StructureNotifyMask);
        XMapWindow(host->display, host->container);
        if (!probe_x11_wait_mapped(host, host->container, error, error_size)) {
            return false;
        }
        parent = host->container;
    }
    host->clap_parent = parent;
    if (host->no_plugin) {
        host->gui = XCreateSimpleWindow(
            host->display, parent, 0, 0, 320, 200, 0, 0, 0x4080c0
        );
        if (host->gui == None) {
            snprintf(error, error_size, "XCreateSimpleWindow failed for GUI");
            return false;
        }
        XSelectInput(
            host->display,
            host->gui,
            StructureNotifyMask | PointerMotionMask
        );
        XMapWindow(host->display, host->gui);
        if (!probe_x11_wait_mapped(host, host->gui, error, error_size)) {
            return false;
        }
    }
    host->opened = true;
    return x11_sync(host, "opening GUI hierarchy", error, error_size);
}

bool probe_x11_place(
    probe_host_t *host,
    int x,
    int y,
    unsigned int width,
    unsigned int height,
    char *error,
    size_t error_size
) {
    int current_x;
    int current_y;
    unsigned int current_width;
    unsigned int current_height;
    if (!host->opened || host->gui == None || width == 0 || height == 0) {
        snprintf(error, error_size, "place requires an open GUI and positive size");
        return false;
    }
    host->configure_observed = false;
    host->synthetic_send_event = false;
    host->synthetic_window = None;
    if (!probe_x11_geometry(
            host,
            &current_x,
            &current_y,
            &current_width,
            &current_height,
            error,
            error_size
        )) {
        return false;
    }
    if (current_x == x && current_y == y && current_width == width &&
        current_height == height) {
        return true;
    }
    probe_x11_drain_events(host);
    if (!host->no_plugin && host->hierarchy == PROBE_HIERARCHY_FLAT) {
        XMoveResizeWindow(
            host->display,
            host->container,
            x,
            y,
            width,
            height
        );
    } else if (host->hierarchy != PROBE_HIERARCHY_FLAT) {
        XMoveResizeWindow(
            host->display,
            host->outer,
            x - intermediate_x - container_x,
            y - intermediate_y - container_y,
            width + intermediate_x + container_x,
            height + intermediate_y + container_y
        );
        XMoveResizeWindow(
            host->display,
            host->intermediate,
            intermediate_x,
            intermediate_y,
            width + container_x,
            height + container_y
        );
        XMoveResizeWindow(
            host->display, host->container, container_x, container_y, width, height
        );
    } else if (host->hierarchy == PROBE_HIERARCHY_FLAT) {
        XMoveResizeWindow(host->display, host->gui, x, y, width, height);
    }
    XFlush(host->display);
    Window configured = host->hierarchy != PROBE_HIERARCHY_FLAT
                            ? host->outer
                            : !host->no_plugin ? host->container : host->gui;
    if (!wait_for_configure(host, configured, false, error, error_size) ||
        !probe_x11_geometry(
            host,
            &current_x,
            &current_y,
            &current_width,
            &current_height,
            error,
            error_size
        )) {
        return false;
    }
    if (current_x != x || current_y != y || current_width != width ||
        current_height != height) {
        snprintf(error, error_size, "placed GUI geometry did not match requested bounds");
        return false;
    }
    return true;
}

bool probe_x11_geometry(
    probe_host_t *host,
    int *x,
    int *y,
    unsigned int *width,
    unsigned int *height,
    char *error,
    size_t error_size
) {
    Window root;
    int local_x;
    int local_y;
    unsigned int border;
    unsigned int depth;
    Window child;
    if (host->gui == None ||
        XGetGeometry(
            host->display,
            host->gui,
            &root,
            &local_x,
            &local_y,
            width,
            height,
            &border,
            &depth
        ) == 0) {
        snprintf(error, error_size, "XGetGeometry failed");
        return false;
    }
    if (XTranslateCoordinates(
            host->display, host->gui, host->root, 0, 0, x, y, &child
        ) == 0) {
        snprintf(error, error_size, "XTranslateCoordinates failed");
        return false;
    }
    return x11_sync(host, "querying GUI geometry", error, error_size);
}

bool probe_x11_resize(
    probe_host_t *host,
    unsigned int width,
    unsigned int height,
    char *error,
    size_t error_size
) {
    int current_x;
    int current_y;
    unsigned int current_width;
    unsigned int current_height;
    unsigned int accepted_width = width;
    unsigned int accepted_height = height;
    if (width == 0 || height == 0 || host->gui == None) {
        snprintf(error, error_size, "resize requires an open GUI and positive size");
        return false;
    }
    host->configure_observed = false;
    host->synthetic_send_event = false;
    if (!probe_x11_geometry(
            host,
            &current_x,
            &current_y,
            &current_width,
            &current_height,
            error,
            error_size
        )) {
        return false;
    }
    if (host->no_plugin && current_width == width && current_height == height) {
        return true;
    }
    probe_x11_drain_events(host);
    if (!host->no_plugin) {
        if (host->plugin_gui == NULL ||
            !host->plugin_gui->set_size(host->plugin, width, height)) {
            snprintf(error, error_size, "CLAP GUI rejected set_size");
            return false;
        }
        if (!host->plugin_gui->get_size(
                host->plugin, &accepted_width, &accepted_height
            ) ||
            accepted_width == 0 || accepted_height == 0) {
            snprintf(error, error_size, "CLAP GUI did not report its accepted size");
            return false;
        }
    } else {
        XResizeWindow(host->display, host->gui, width, height);
        if (host->container != None &&
            host->hierarchy != PROBE_HIERARCHY_SYNTHETIC_ABSOLUTE) {
            XResizeWindow(host->display, host->container, width, height);
        }
    }
    XFlush(host->display);
    if (!x11_sync(host, "applying GUI resize", error, error_size) ||
        !probe_x11_geometry(
            host,
            &current_x,
            &current_y,
            &width,
            &height,
            error,
            error_size
        )) {
        return false;
    }
    if (host->no_plugin) {
        if (!wait_for_configure(host, host->gui, false, error, error_size)) {
            return false;
        }
    } else if ((width != accepted_width || height != accepted_height) &&
               !wait_for_resize_convergence(
                   host,
                   accepted_width,
                   accepted_height,
                   error,
                   error_size
               )) {
        return false;
    } else if (!host->no_plugin) {
        observe_ready_resize(host, accepted_width, accepted_height);
    }
    if (!probe_x11_geometry(
            host,
            &current_x,
            &current_y,
            &width,
            &height,
            error,
            error_size
        )) {
        return false;
    }
    if (width != accepted_width || height != accepted_height) {
        snprintf(error, error_size, "accepted GUI size and observed geometry disagree");
        return false;
    }
    if (host->outer != None) {
        XResizeWindow(
            host->display,
            host->outer,
            accepted_width + intermediate_x + container_x,
            accepted_height + intermediate_y + container_y
        );
        XResizeWindow(
            host->display,
            host->intermediate,
            accepted_width + container_x,
            accepted_height + container_y
        );
        XResizeWindow(host->display, host->container, accepted_width, accepted_height);
        if (!x11_sync(host, "resizing nested host hierarchy", error, error_size)) {
            return false;
        }
    } else if (host->container != None) {
        XResizeWindow(host->display, host->container, accepted_width, accepted_height);
        if (!x11_sync(host, "resizing host container", error, error_size)) {
            return false;
        }
    }
    return true;
}

bool probe_x11_synthetic_configure(
    probe_host_t *host,
    int x,
    int y,
    unsigned int width,
    unsigned int height,
    char *error,
    size_t error_size
) {
    XEvent event;
    if (host->hierarchy != PROBE_HIERARCHY_SYNTHETIC_ABSOLUTE) {
        snprintf(error, error_size, "synthetic_configure requires synthetic-absolute mode");
        return false;
    }
    if (!probe_x11_place(host, x, y, width, height, error, error_size)) {
        return false;
    }
    memset(&event, 0, sizeof(event));
    event.xconfigure.type = ConfigureNotify;
    event.xconfigure.display = host->display;
    Window target = host->clap_parent;
    event.xconfigure.event = target;
    event.xconfigure.window = target;
    event.xconfigure.x = x;
    event.xconfigure.y = y;
    event.xconfigure.width = (int)width;
    event.xconfigure.height = (int)height;
    event.xconfigure.send_event = True;
    if (XSendEvent(host->display, target, False, StructureNotifyMask, &event) == 0) {
        snprintf(error, error_size, "XSendEvent failed for synthetic ConfigureNotify");
        return false;
    }
    host->configure_observed = false;
    host->synthetic_send_event = false;
    host->synthetic_window = target;
    XFlush(host->display);
    return wait_for_configure(host, target, true, error, error_size);
}

bool probe_x11_warp(
    probe_host_t *host,
    int x,
    int y,
    char *error,
    size_t error_size
) {
    if (!host->xtest_available || XTestFakeMotionEvent(host->display, -1, x, y, CurrentTime) == 0) {
        snprintf(error, error_size, "XTestFakeMotionEvent failed");
        return false;
    }
    XFlush(host->display);
    return x11_sync(host, "warping pointer", error, error_size);
}

bool probe_x11_query_pointer(
    probe_host_t *host,
    int *x,
    int *y,
    unsigned int *state,
    char *error,
    size_t error_size
) {
    Window root;
    Window child;
    int window_x;
    int window_y;
    if (XQueryPointer(
            host->display,
            host->root,
            &root,
            &child,
            x,
            y,
            &window_x,
            &window_y,
            state
        ) == 0) {
        snprintf(error, error_size, "XQueryPointer failed");
        return false;
    }
    return x11_sync(host, "querying pointer", error, error_size);
}

static bool pointer_targets_gui(probe_host_t *host) {
    Window current = host->root;
    bool found = current == host->gui;
    for (;;) {
        Window root;
        Window child;
        int root_x;
        int root_y;
        int local_x;
        int local_y;
        unsigned int state;
        if (XQueryPointer(
                host->display,
                current,
                &root,
                &child,
                &root_x,
                &root_y,
                &local_x,
                &local_y,
                &state
            ) == 0 ||
            child == None) {
            return found;
        }
        if (child == host->gui) {
            found = true;
        }
        current = child;
    }
}

bool probe_x11_button(
    probe_host_t *host,
    int x,
    int y,
    unsigned int button,
    char *error,
    size_t error_size
) {
    unsigned int pressed_state;
    unsigned int released_state;
    unsigned int button_mask;
    bool pressed_over_gui;
    bool released_over_gui;
    if (button == 0 || !probe_x11_warp(host, x, y, error, error_size)) {
        return false;
    }
    switch (button) {
    case 1:
        button_mask = Button1Mask;
        break;
    case 2:
        button_mask = Button2Mask;
        break;
    case 3:
        button_mask = Button3Mask;
        break;
    case 4:
        button_mask = Button4Mask;
        break;
    case 5:
        button_mask = Button5Mask;
        break;
    default:
        snprintf(error, error_size, "unsupported X11 button %u", button);
        return false;
    }
    host->button_press_observed = false;
    host->button_release_observed = false;
    if (XTestFakeButtonEvent(host->display, button, True, CurrentTime) == 0 ||
        !x11_sync(host, "pressing pointer button", error, error_size) ||
        !probe_x11_query_pointer(
            host,
            &host->button_root_x,
            &host->button_root_y,
            &pressed_state,
            error,
            error_size
        )) {
        return false;
    }
    pressed_over_gui = pointer_targets_gui(host);
    host->button_press_state = pressed_state;
    host->button_press_observed =
        (pressed_state & button_mask) != 0 && pressed_over_gui;
    if (XTestFakeButtonEvent(host->display, button, False, CurrentTime) == 0 ||
        !x11_sync(host, "releasing pointer button", error, error_size) ||
        !probe_x11_query_pointer(
            host,
            &host->button_root_x,
            &host->button_root_y,
            &released_state,
            error,
            error_size
        )) {
        return false;
    }
    released_over_gui = pointer_targets_gui(host);
    host->button_release_state = released_state;
    host->button_release_observed =
        (released_state & button_mask) == 0 && released_over_gui;
    host->button_state = released_state;
    if (!host->button_press_observed || !host->button_release_observed) {
        snprintf(error, error_size, "XQueryPointer did not observe button state transition");
        return false;
    }
    return true;
}

void probe_x11_drain_events(probe_host_t *host) {
    while (host->display != NULL && XPending(host->display) > 0) {
        XEvent event;
        XNextEvent(host->display, &event);
    }
}
