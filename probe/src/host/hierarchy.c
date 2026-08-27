#define _POSIX_C_SOURCE 200809L

#include "host.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int64_t monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int only_child(
    Display *display,
    Window parent,
    Window *child,
    char *error,
    size_t error_size
) {
    Window root;
    Window reported_parent;
    Window *children = NULL;
    unsigned int child_count = 0;
    if (XQueryTree(
            display,
            parent,
            &root,
            &reported_parent,
            &children,
            &child_count
        ) == 0) {
        snprintf(error, error_size, "XQueryTree failed for window %lu", parent);
        return -1;
    }
    if (child_count == 0) {
        if (children != NULL) {
            XFree(children);
        }
        snprintf(error, error_size, "plugin window chain under %lu has no child yet", parent);
        return 0;
    }
    if (child_count > 1) {
        if (children != NULL) {
            XFree(children);
        }
        snprintf(
            error,
            error_size,
            "ambiguous plugin window chain under %lu: expected 1 direct child, found %u",
            parent,
            child_count
        );
        return -1;
    }
    *child = children[0];
    XFree(children);
    return 1;
}

bool probe_discover_plugin_chain(
    Display *display,
    Window parent,
    Window *wrapper,
    Window *wine_window,
    char *error,
    size_t error_size
) {
    int64_t deadline = monotonic_milliseconds() + 2000;
    if (XSelectInput(display, parent, StructureNotifyMask | SubstructureNotifyMask) == 0) {
        snprintf(error, error_size, "XSelectInput failed for plugin parent %lu", parent);
        return false;
    }
    XSync(display, False);
    for (;;) {
        char attempt_error[256];
        int wrapper_result =
            only_child(display, parent, wrapper, attempt_error, sizeof(attempt_error));
        if (wrapper_result < 0) {
            snprintf(error, error_size, "%s", attempt_error);
            return false;
        }
        if (wrapper_result > 0) {
            if (XSelectInput(
                    display, *wrapper, StructureNotifyMask | SubstructureNotifyMask
                ) == 0) {
                snprintf(error, error_size, "XSelectInput failed for wrapper %lu", *wrapper);
                return false;
            }
            XSync(display, False);
            int wine_result = only_child(
                display, *wrapper, wine_window, attempt_error, sizeof(attempt_error)
            );
            if (wine_result < 0) {
                snprintf(error, error_size, "%s", attempt_error);
                return false;
            }
            if (wine_result > 0) {
                return true;
            }
        }
        int64_t now = monotonic_milliseconds();
        if (now < 0 || now >= deadline) {
            snprintf(error, error_size, "%s", attempt_error);
            return false;
        }
        struct pollfd descriptor = {
            .fd = ConnectionNumber(display),
            .events = POLLIN,
            .revents = 0,
        };
        if (poll(&descriptor, 1, (int)(deadline - now)) < 0 && errno != EINTR) {
            snprintf(error, error_size, "polling plugin hierarchy failed: %s", strerror(errno));
            return false;
        }
        while (XPending(display) > 0) {
            XEvent event;
            XNextEvent(display, &event);
        }
    }
}
