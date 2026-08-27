#ifndef CLAP_PROBE_HOST_H
#define CLAP_PROBE_HOST_H

#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>

#include <X11/Xlib.h>
#include <clap/clap.h>
#include <clap/ext/gui.h>
#include <json-c/json.h>

typedef enum probe_hierarchy {
    PROBE_HIERARCHY_FLAT,
    PROBE_HIERARCHY_NESTED,
    PROBE_HIERARCHY_SYNTHETIC_ABSOLUTE,
} probe_hierarchy_t;

typedef struct probe_host {
    Display *display;
    Window root;
    Window outer;
    Window intermediate;
    Window container;
    Window clap_parent;
    Window wrapper;
    Window wine_window;
    Window gui;
    probe_hierarchy_t hierarchy;
    const char *token;
    uint64_t input_seq;
    uint64_t output_seq;
    bool xtest_available;
    bool no_plugin;
    bool opened;
    bool configure_observed;
    bool synthetic_send_event;
    int configure_event_x;
    int configure_event_y;
    Window synthetic_window;
    bool button_press_observed;
    bool button_release_observed;
    int button_root_x;
    int button_root_y;
    unsigned int button_state;
    unsigned int button_press_state;
    unsigned int button_release_state;
    int callback_pipe[2];
    pthread_mutex_t callback_mutex;
    bool callback_pending;
    pthread_t main_thread;

    void *module;
    const clap_plugin_entry_t *entry;
    const clap_plugin_t *plugin;
    const clap_plugin_gui_t *plugin_gui;
    bool entry_initialized;
    bool plugin_initialized;
    bool plugin_activated;
    bool gui_created;
    bool gui_shown;
    clap_host_t clap_host;
} probe_host_t;

bool probe_emit(probe_host_t *host, const char *type, json_object *fields);
bool probe_emit_error(probe_host_t *host, const char *message);

bool probe_x11_init(probe_host_t *host, char *error, size_t error_size);
void probe_x11_destroy(probe_host_t *host);
bool probe_x11_open(probe_host_t *host, char *error, size_t error_size);
bool probe_x11_place(
    probe_host_t *host,
    int x,
    int y,
    unsigned int width,
    unsigned int height,
    char *error,
    size_t error_size
);
bool probe_x11_geometry(
    probe_host_t *host,
    int *x,
    int *y,
    unsigned int *width,
    unsigned int *height,
    char *error,
    size_t error_size
);
bool probe_x11_resize(
    probe_host_t *host,
    unsigned int width,
    unsigned int height,
    char *error,
    size_t error_size
);
bool probe_x11_synthetic_configure(
    probe_host_t *host,
    int x,
    int y,
    unsigned int width,
    unsigned int height,
    char *error,
    size_t error_size
);
bool probe_x11_warp(
    probe_host_t *host,
    int x,
    int y,
    char *error,
    size_t error_size
);
bool probe_x11_button(
    probe_host_t *host,
    int x,
    int y,
    unsigned int button,
    char *error,
    size_t error_size
);
bool probe_x11_query_pointer(
    probe_host_t *host,
    int *x,
    int *y,
    unsigned int *state,
    char *error,
    size_t error_size
);
void probe_x11_drain_events(probe_host_t *host);
bool probe_x11_wait_mapped(
    probe_host_t *host,
    Window window,
    char *error,
    size_t error_size
);

bool probe_discover_plugin_chain(
    Display *display,
    Window parent,
    Window *wrapper,
    Window *wine_window,
    char *error,
    size_t error_size
);

bool probe_clap_open(
    probe_host_t *host,
    const char *path,
    const char *plugin_id,
    char *error,
    size_t error_size
);
void probe_clap_close(probe_host_t *host);
void probe_clap_host_initialize(probe_host_t *host);
bool probe_clap_dispatch_callback(probe_host_t *host);

#endif
