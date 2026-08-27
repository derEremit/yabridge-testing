#define _POSIX_C_SOURCE 200809L

#include "host.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <probe/protocol.h>

static bool valid_utf8(const unsigned char *text, size_t length) {
    size_t index = 0;
    while (index < length) {
        unsigned char first = text[index++];
        if (first <= 0x7f) {
            if (first == 0) {
                return false;
            }
            continue;
        }
        unsigned int remaining;
        uint32_t codepoint;
        if (first >= 0xc2 && first <= 0xdf) {
            remaining = 1;
            codepoint = first & 0x1f;
        } else if (first >= 0xe0 && first <= 0xef) {
            remaining = 2;
            codepoint = first & 0x0f;
        } else if (first >= 0xf0 && first <= 0xf4) {
            remaining = 3;
            codepoint = first & 0x07;
        } else {
            return false;
        }
        if (index + remaining > length) {
            return false;
        }
        for (unsigned int offset = 0; offset < remaining; ++offset) {
            unsigned char continuation = text[index++];
            if ((continuation & 0xc0) != 0x80) {
                return false;
            }
            codepoint = (codepoint << 6) | (continuation & 0x3f);
        }
        if ((remaining == 2 && codepoint < 0x800) ||
            (remaining == 3 && codepoint < 0x10000) ||
            codepoint > 0x10ffff ||
            (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
            return false;
        }
    }
    return true;
}

static int read_protocol_line(unsigned char *buffer, size_t capacity, size_t *length) {
    for (;;) {
        unsigned char byte;
        ssize_t received = read(STDIN_FILENO, &byte, 1);
        if (received == 0) {
            return *length == 0 ? 0 : -2;
        }
        if (received < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return 2;
            }
            return -3;
        }
        if (*length >= capacity) {
            return -1;
        }
        buffer[(*length)++] = byte;
        if (byte == '\n') {
            return 1;
        }
    }
}

bool probe_emit(probe_host_t *host, const char *type, json_object *fields) {
    json_object *message = json_object_new_object();
    if (message == NULL) {
        fprintf(stderr, "clap-probe-host: could not allocate protocol event\n");
        return false;
    }
    json_object_object_add(message, "v", json_object_new_int(1));
    json_object_object_add(message, "seq", json_object_new_int64((int64_t)host->output_seq++));
    json_object_object_add(message, "type", json_object_new_string(type));
    json_object_object_add(message, "token", json_object_new_string(host->token));
    if (fields != NULL) {
        json_object_object_foreach(fields, key, value) {
            json_object_object_add(message, key, json_object_get(value));
        }
    }
    if (host->display != NULL) {
        XSync(host->display, False);
    }
    const char *encoded = json_object_to_json_string_ext(message, JSON_C_TO_STRING_PLAIN);
    size_t length = strlen(encoded);
    bool success = length + 1 <= PROBE_MAX_LINE &&
                   fwrite(encoded, 1, length, stdout) == length &&
                   fputc('\n', stdout) != EOF &&
                   fflush(stdout) == 0;
    if (!success) {
        fprintf(stderr, "clap-probe-host: protocol output failed or exceeded 64 KiB\n");
    }
    json_object_put(message);
    return success;
}

bool probe_emit_error(probe_host_t *host, const char *message) {
    json_object *fields = json_object_new_object();
    json_object_object_add(fields, "message", json_object_new_string(message));
    bool success = probe_emit(host, "error", fields);
    json_object_put(fields);
    return success;
}

static bool integer_field(
    json_object *command,
    const char *name,
    int64_t minimum,
    int64_t maximum,
    int64_t *result
) {
    json_object *value;
    if (!json_object_object_get_ex(command, name, &value) ||
        json_object_get_type(value) != json_type_int) {
        return false;
    }
    int64_t parsed = json_object_get_int64(value);
    if (parsed < minimum || parsed > maximum) {
        return false;
    }
    *result = parsed;
    return true;
}

static bool command_envelope(
    probe_host_t *host,
    json_object *command,
    const char **type,
    char *error,
    size_t error_size
) {
    json_object *version;
    json_object *sequence;
    json_object *type_value;
    json_object *token;
    if (json_object_get_type(command) != json_type_object ||
        !json_object_object_get_ex(command, "v", &version) ||
        json_object_get_type(version) != json_type_int ||
        json_object_get_int64(version) != 1) {
        snprintf(error, error_size, "unsupported protocol version");
        return false;
    }
    if (!json_object_object_get_ex(command, "seq", &sequence) ||
        json_object_get_type(sequence) != json_type_int ||
        json_object_get_int64(sequence) < 0) {
        snprintf(error, error_size, "sequence must be a nonnegative integer");
        return false;
    }
    uint64_t received_sequence = (uint64_t)json_object_get_int64(sequence);
    if (received_sequence != host->input_seq) {
        snprintf(
            error,
            error_size,
            received_sequence < host->input_seq
                ? "duplicate sequence number"
                : "out-of-order sequence number"
        );
        return false;
    }
    if (!json_object_object_get_ex(command, "token", &token) ||
        json_object_get_type(token) != json_type_string ||
        strcmp(json_object_get_string(token), host->token) != 0) {
        snprintf(error, error_size, "invalid authentication token");
        return false;
    }
    if (!json_object_object_get_ex(command, "type", &type_value) ||
        json_object_get_type(type_value) != json_type_string) {
        snprintf(error, error_size, "command type must be a string");
        return false;
    }
    *type = json_object_get_string(type_value);
    ++host->input_seq;
    return true;
}

static bool emit_geometry(probe_host_t *host, char *error, size_t error_size) {
    int x;
    int y;
    int parent_x;
    int parent_y;
    unsigned int width;
    unsigned int height;
    unsigned int border;
    unsigned int depth;
    Window parent;
    if (!probe_x11_geometry(
            host, &x, &y, &width, &height, error, error_size
        )) {
        return false;
    }
    if (XGetGeometry(
            host->display,
            host->gui,
            &parent,
            &parent_x,
            &parent_y,
            &width,
            &height,
            &border,
            &depth
        ) == 0) {
        snprintf(error, error_size, "XGetGeometry failed for parent-relative geometry");
        return false;
    }
    json_object *fields = json_object_new_object();
    json_object_object_add(fields, "x", json_object_new_int(x));
    json_object_object_add(fields, "y", json_object_new_int(y));
    json_object_object_add(fields, "w", json_object_new_int64(width));
    json_object_object_add(fields, "h", json_object_new_int64(height));
    json_object_object_add(fields, "parent_x", json_object_new_int(parent_x));
    json_object_object_add(fields, "parent_y", json_object_new_int(parent_y));
    json_object_object_add(
        fields, "configure_observed", json_object_new_boolean(host->configure_observed)
    );
    if (host->synthetic_send_event) {
        json_object_object_add(fields, "synthetic_send_event", json_object_new_boolean(true));
        json_object_object_add(fields, "event_x", json_object_new_int(host->configure_event_x));
        json_object_object_add(fields, "event_y", json_object_new_int(host->configure_event_y));
        json_object_object_add(
            fields,
            "synthetic_window",
            json_object_new_int64((int64_t)host->synthetic_window)
        );
    }
    bool success = probe_emit(host, "geometry", fields);
    json_object_object_add(fields, "window", json_object_new_int64((int64_t)host->gui));
    success = probe_emit(host, "x11", fields) && success;
    json_object_put(fields);
    return success;
}

static bool process_command(
    probe_host_t *host,
    json_object *command,
    const char *plugin_path,
    const char *plugin_id,
    bool *closing,
    char *error,
    size_t error_size
) {
    const char *type;
    int64_t x;
    int64_t y;
    int64_t width;
    int64_t height;
    int64_t button;
    if (!command_envelope(host, command, &type, error, error_size)) {
        return false;
    }
    if (strcmp(type, "open") == 0) {
        if (!probe_x11_open(host, error, error_size)) {
            return false;
        }
        if (!host->no_plugin &&
            !probe_clap_open(host, plugin_path, plugin_id, error, error_size)) {
            return false;
        }
        json_object *fields = json_object_new_object();
        json_object_object_add(fields, "hwnd", json_object_new_int64((int64_t)host->gui));
        json_object_object_add(
            fields, "clap_parent", json_object_new_int64((int64_t)host->clap_parent)
        );
        json_object_object_add(fields, "outer", json_object_new_int64((int64_t)host->outer));
        json_object_object_add(
            fields, "intermediate", json_object_new_int64((int64_t)host->intermediate)
        );
        json_object_object_add(
            fields,
            "hierarchy_offset_x",
            json_object_new_int(host->hierarchy == PROBE_HIERARCHY_FLAT ? 0 : 56)
        );
        json_object_object_add(
            fields,
            "hierarchy_offset_y",
            json_object_new_int(host->hierarchy == PROBE_HIERARCHY_FLAT ? 0 : 64)
        );
        if (!host->no_plugin) {
            json_object_object_add(
                fields, "wrapper", json_object_new_int64((int64_t)host->wrapper)
            );
            json_object_object_add(
                fields, "wine_window", json_object_new_int64((int64_t)host->wine_window)
            );
        }
        bool success = probe_emit(host, "gui_opened", fields);
        json_object_put(fields);
        if (success && !host->no_plugin) {
            fields = json_object_new_object();
            json_object_object_add(fields, "event", json_object_new_string("gui_shown"));
            success = probe_emit(host, "clap", fields);
            json_object_put(fields);
        }
        return success;
    }
    if (strcmp(type, "place") == 0) {
        if (!integer_field(command, "x", INT32_MIN, INT32_MAX, &x) ||
            !integer_field(command, "y", INT32_MIN, INT32_MAX, &y) ||
            !integer_field(command, "w", 1, UINT32_MAX, &width) ||
            !integer_field(command, "h", 1, UINT32_MAX, &height)) {
            snprintf(error, error_size, "place has invalid geometry fields");
            return false;
        }
        return probe_x11_place(
                   host,
                   (int)x,
                   (int)y,
                   (unsigned int)width,
                   (unsigned int)height,
                   error,
                   error_size
               ) &&
               emit_geometry(host, error, error_size);
    }
    if (strcmp(type, "geometry") == 0) {
        host->configure_observed = false;
        host->synthetic_send_event = false;
        host->configure_event_x = 0;
        host->configure_event_y = 0;
        return emit_geometry(host, error, error_size);
    }
    if (strcmp(type, "resize") == 0) {
        if (!integer_field(command, "w", 1, UINT32_MAX, &width) ||
            !integer_field(command, "h", 1, UINT32_MAX, &height)) {
            snprintf(error, error_size, "resize has invalid size fields");
            return false;
        }
        return probe_x11_resize(
                   host,
                   (unsigned int)width,
                   (unsigned int)height,
                   error,
                   error_size
               ) &&
               emit_geometry(host, error, error_size);
    }
    if (strcmp(type, "synthetic_configure") == 0) {
        if (!integer_field(command, "x", INT32_MIN, INT32_MAX, &x) ||
            !integer_field(command, "y", INT32_MIN, INT32_MAX, &y) ||
            !integer_field(command, "w", 1, UINT32_MAX, &width) ||
            !integer_field(command, "h", 1, UINT32_MAX, &height)) {
            snprintf(error, error_size, "synthetic_configure has invalid geometry fields");
            return false;
        }
        return probe_x11_synthetic_configure(
                   host,
                   (int)x,
                   (int)y,
                   (unsigned int)width,
                   (unsigned int)height,
                   error,
                   error_size
               ) &&
               emit_geometry(host, error, error_size);
    }
    if (strcmp(type, "warp") == 0 || strcmp(type, "button") == 0) {
        if (!integer_field(command, "x", INT32_MIN, INT32_MAX, &x) ||
            !integer_field(command, "y", INT32_MIN, INT32_MAX, &y)) {
            snprintf(error, error_size, "%s has invalid coordinates", type);
            return false;
        }
        json_object *fields = json_object_new_object();
        bool success;
        if (strcmp(type, "button") == 0) {
            if (!integer_field(command, "button", 1, 255, &button) ||
                !probe_x11_button(
                    host, (int)x, (int)y, (unsigned int)button, error, error_size
                )) {
                json_object_put(fields);
                if (error[0] == '\0') {
                    snprintf(error, error_size, "button has an invalid button number");
                }
                return false;
            }
            json_object_object_add(fields, "button", json_object_new_int64(button));
            json_object_object_add(
                fields,
                "press_observed",
                json_object_new_boolean(host->button_press_observed)
            );
            json_object_object_add(
                fields,
                "release_observed",
                json_object_new_boolean(host->button_release_observed)
            );
            json_object_object_add(fields, "state", json_object_new_int64(host->button_state));
            json_object_object_add(
                fields, "press_state", json_object_new_int64(host->button_press_state)
            );
            json_object_object_add(
                fields, "release_state", json_object_new_int64(host->button_release_state)
            );
            x = host->button_root_x;
            y = host->button_root_y;
        } else if (!probe_x11_warp(host, (int)x, (int)y, error, error_size)) {
            json_object_put(fields);
            return false;
        } else {
            unsigned int state;
            int observed_x;
            int observed_y;
            if (!probe_x11_query_pointer(
                    host,
                    &observed_x,
                    &observed_y,
                    &state,
                    error,
                    error_size
                )) {
                json_object_put(fields);
                return false;
            }
            x = observed_x;
            y = observed_y;
            json_object_object_add(fields, "state", json_object_new_int64(state));
        }
        json_object_object_add(fields, "x", json_object_new_int64(x));
        json_object_object_add(fields, "y", json_object_new_int64(y));
        success = probe_emit(host, "warped", fields);
        json_object_put(fields);
        return success;
    }
    if (strcmp(type, "close") == 0) {
        *closing = true;
        return true;
    }
    snprintf(error, error_size, "unrecognized command type");
    return false;
}

static void usage(const char *program) {
    fprintf(
        stderr,
        "usage: %s (--no-plugin | --plugin PATH) "
        "[--plugin-id ID] [--hierarchy flat|nested|synthetic-absolute]\n",
        program
    );
}

int main(int argc, char **argv) {
    probe_host_t host;
    const char *plugin_path = NULL;
    const char *plugin_id = NULL;
    const char *hierarchy_name = "flat";
    unsigned char line[PROBE_MAX_LINE];
    char error[512] = {0};
    int status = EXIT_FAILURE;
    bool callback_mutex_initialized = false;
    memset(&host, 0, sizeof(host));
    host.callback_pipe[0] = -1;
    host.callback_pipe[1] = -1;
    host.main_thread = pthread_self();
    host.hierarchy = PROBE_HIERARCHY_FLAT;
    for (int index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--no-plugin") == 0) {
            host.no_plugin = true;
        } else if (strcmp(argv[index], "--plugin") == 0 && index + 1 < argc) {
            plugin_path = argv[++index];
        } else if (strcmp(argv[index], "--plugin-id") == 0 && index + 1 < argc) {
            plugin_id = argv[++index];
        } else if (strcmp(argv[index], "--hierarchy") == 0 && index + 1 < argc) {
            hierarchy_name = argv[++index];
        } else {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }
    if (strcmp(hierarchy_name, "nested") == 0) {
        host.hierarchy = PROBE_HIERARCHY_NESTED;
    } else if (strcmp(hierarchy_name, "synthetic-absolute") == 0) {
        host.hierarchy = PROBE_HIERARCHY_SYNTHETIC_ABSOLUTE;
    } else if (strcmp(hierarchy_name, "flat") != 0) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    host.token = getenv("YABRIDGE_PROBE_TOKEN");
    if (host.token == NULL || host.token[0] == '\0' ||
        (host.no_plugin == (plugin_path != NULL))) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    if (pthread_mutex_init(&host.callback_mutex, NULL) != 0) {
        fprintf(stderr, "clap-probe-host: callback mutex initialization failed\n");
        goto cleanup;
    }
    callback_mutex_initialized = true;
    if (pipe(host.callback_pipe) != 0 ||
        fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(host.callback_pipe[0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(host.callback_pipe[1], F_SETFL, O_NONBLOCK) < 0) {
        fprintf(stderr, "clap-probe-host: callback wakeup pipe failed: %s\n", strerror(errno));
        goto cleanup;
    }
    probe_clap_host_initialize(&host);
    if (!probe_x11_init(&host, error, sizeof(error))) {
        fprintf(stderr, "clap-probe-host: %s\n", error);
        goto cleanup;
    }
    json_object *ready = json_object_new_object();
    json_object_object_add(ready, "mode", json_object_new_string(hierarchy_name));
    if (!probe_emit(&host, "ready", ready)) {
        json_object_put(ready);
        goto cleanup;
    }
    json_object_put(ready);
    size_t length = 0;
    for (;;) {
        struct pollfd descriptors[3] = {
            {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP, .revents = 0},
            {
                .fd = ConnectionNumber(host.display),
                .events = POLLIN,
                .revents = 0,
            },
            {.fd = host.callback_pipe[0], .events = POLLIN, .revents = 0},
        };
        int selected = poll(descriptors, 3, -1);
        if (selected < 0) {
            if (errno == EINTR) {
                continue;
            }
            probe_emit_error(&host, "host event poll failed");
            break;
        }
        if ((descriptors[1].revents & POLLIN) != 0) {
            probe_x11_drain_events(&host);
        }
        if ((descriptors[2].revents & POLLIN) != 0 &&
            probe_clap_dispatch_callback(&host)) {
            json_object *callback = json_object_new_object();
            json_object_object_add(callback, "event", json_object_new_string("callback"));
            json_object_object_add(
                callback,
                "main_thread",
                json_object_new_boolean(pthread_equal(pthread_self(), host.main_thread))
            );
            if (!probe_emit(&host, "clap", callback)) {
                json_object_put(callback);
                break;
            }
            json_object_put(callback);
        }
        if ((descriptors[0].revents & (POLLIN | POLLHUP)) == 0) {
            continue;
        }
        int read_result = read_protocol_line(line, sizeof(line), &length);
        if (read_result == 2) {
            continue;
        }
        if (read_result == 0) {
            status = EXIT_SUCCESS;
            break;
        }
        if (read_result < 0) {
            const char *message = read_result == -1
                                      ? "line exceeds 64 KiB limit"
                                      : read_result == -2 ? "truncated protocol line"
                                                          : "protocol stdin read failed";
            probe_emit_error(&host, message);
            break;
        }
        if (!valid_utf8(line, length)) {
            probe_emit_error(&host, "invalid UTF-8");
            break;
        }
        line[length - 1] = '\0';
        json_tokener *tokener = json_tokener_new();
        if (tokener == NULL) {
            probe_emit_error(&host, "could not allocate JSON parser");
            break;
        }
        json_tokener_set_flags(tokener, JSON_TOKENER_STRICT);
        json_object *command =
            json_tokener_parse_ex(tokener, (const char *)line, (int)(length - 1));
        enum json_tokener_error parse_error = json_tokener_get_error(tokener);
        size_t parsed = json_tokener_get_parse_end(tokener);
        json_tokener_free(tokener);
        if (parse_error != json_tokener_success || command == NULL ||
            parsed != length - 1) {
            if (command != NULL) {
                json_object_put(command);
            }
            probe_emit_error(&host, "malformed JSON");
            break;
        }
        bool closing = false;
        error[0] = '\0';
        bool success = process_command(
            &host,
            command,
            plugin_path,
            plugin_id,
            &closing,
            error,
            sizeof(error)
        );
        json_object_put(command);
        if (!success) {
            probe_emit_error(&host, error[0] != '\0' ? error : "command failed");
            break;
        }
        if (closing) {
            status = EXIT_SUCCESS;
            break;
        }
        length = 0;
    }

cleanup:
    probe_clap_close(&host);
    probe_x11_destroy(&host);
    if (host.callback_pipe[0] >= 0) {
        close(host.callback_pipe[0]);
    }
    if (host.callback_pipe[1] >= 0) {
        close(host.callback_pipe[1]);
    }
    if (callback_mutex_initialized) {
        pthread_mutex_destroy(&host.callback_mutex);
    }
    return status;
}
