#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <X11/Xlib.h>
#include <clap/clap.h>
#include <clap/ext/gui.h>
#include <clap/factory/plugin-factory.h>

typedef struct fixture_plugin {
    clap_plugin_t plugin;
    const clap_host_t *host;
    Display *display;
    Window wrapper;
    Window ambiguous;
    Window wine;
    Window internal;
    Window parent;
    uint32_t width;
    uint32_t height;
    pthread_t worker;
    bool worker_started;
    pthread_t resize_worker;
    bool resize_worker_started;
} fixture_plugin_t;

static fixture_plugin_t *fixture(const clap_plugin_t *plugin) {
    return plugin->plugin_data;
}

static bool create_hierarchy(fixture_plugin_t *self) {
    self->wrapper = XCreateSimpleWindow(
        self->display, self->parent, 0, 0, self->width, self->height, 0, 0, 0x101010
    );
    self->wine = XCreateSimpleWindow(
        self->display, self->wrapper, 0, 0, self->width, self->height, 0, 0, 0x303030
    );
    self->internal = XCreateSimpleWindow(
        self->display, self->wine, 3, 5, 40, 30, 0, 0, 0x505050
    );
    if (getenv("YABRIDGE_FIXTURE_AMBIGUOUS") != NULL) {
        self->ambiguous = XCreateSimpleWindow(
            self->display, self->parent, 1, 1, 10, 10, 0, 0, 0x707070
        );
    }
    if (self->wrapper == None || self->wine == None || self->internal == None) {
        return false;
    }
    XSelectInput(self->display, self->wine, ButtonPressMask | ButtonReleaseMask);
    XMapWindow(self->display, self->wrapper);
    XMapWindow(self->display, self->wine);
    XMapWindow(self->display, self->internal);
    if (self->ambiguous != None) {
        XMapWindow(self->display, self->ambiguous);
    }
    XSync(self->display, False);
    return true;
}

static void *request_callback_worker(void *data) {
    fixture_plugin_t *self = data;
    if (getenv("YABRIDGE_FIXTURE_DELAY_CHILDREN") != NULL) {
        const struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
        nanosleep(&delay, NULL);
        if (!create_hierarchy(self)) {
            return NULL;
        }
    }
    self->host->request_callback(self->host);
    return NULL;
}

static void apply_resize(fixture_plugin_t *self) {
    if (self->display != NULL) {
        XResizeWindow(self->display, self->wrapper, self->width, self->height);
        XResizeWindow(self->display, self->wine, self->width, self->height);
        XSync(self->display, False);
    }
}

static void *async_resize_worker(void *data) {
    fixture_plugin_t *self = data;
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 200000000};
    nanosleep(&delay, NULL);
    apply_resize(self);
    return NULL;
}

static bool plugin_init(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}

static void gui_destroy(const clap_plugin_t *plugin);

static void plugin_destroy(const clap_plugin_t *plugin) {
    fixture_plugin_t *self = fixture(plugin);
    gui_destroy(plugin);
    free(self);
}

static bool plugin_activate(
    const clap_plugin_t *plugin,
    double sample_rate,
    uint32_t min_frames,
    uint32_t max_frames
) {
    (void)plugin;
    (void)sample_rate;
    (void)min_frames;
    (void)max_frames;
    return true;
}

static void plugin_deactivate(const clap_plugin_t *plugin) {
    (void)plugin;
}

static bool plugin_start_processing(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}

static void plugin_stop_processing(const clap_plugin_t *plugin) {
    (void)plugin;
}

static void plugin_reset(const clap_plugin_t *plugin) {
    (void)plugin;
}

static clap_process_status plugin_process(
    const clap_plugin_t *plugin,
    const clap_process_t *process
) {
    (void)plugin;
    (void)process;
    return CLAP_PROCESS_CONTINUE;
}

static bool gui_is_api_supported(
    const clap_plugin_t *plugin,
    const char *api,
    bool floating
) {
    (void)plugin;
    return !floating && api != NULL && strcmp(api, CLAP_WINDOW_API_X11) == 0;
}

static bool gui_get_preferred_api(
    const clap_plugin_t *plugin,
    const char **api,
    bool *floating
) {
    (void)plugin;
    *api = CLAP_WINDOW_API_X11;
    *floating = false;
    return true;
}

static bool gui_create(const clap_plugin_t *plugin, const char *api, bool floating) {
    return gui_is_api_supported(plugin, api, floating);
}

static void gui_destroy(const clap_plugin_t *plugin) {
    fixture_plugin_t *self = fixture(plugin);
    if (self->worker_started) {
        pthread_join(self->worker, NULL);
        self->worker_started = false;
    }
    if (self->resize_worker_started) {
        pthread_join(self->resize_worker, NULL);
        self->resize_worker_started = false;
    }
    if (self->display != NULL) {
        if (self->wrapper != None) {
            XDestroyWindow(self->display, self->wrapper);
        }
        if (self->ambiguous != None) {
            XDestroyWindow(self->display, self->ambiguous);
        }
        XSync(self->display, False);
        XCloseDisplay(self->display);
        self->display = NULL;
    }
}

static bool gui_set_scale(const clap_plugin_t *plugin, double scale) {
    (void)plugin;
    (void)scale;
    return false;
}

static bool gui_get_size(
    const clap_plugin_t *plugin,
    uint32_t *width,
    uint32_t *height
) {
    fixture_plugin_t *self = fixture(plugin);
    *width = self->width;
    *height = self->height;
    return true;
}

static bool gui_can_resize(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}

static bool gui_get_resize_hints(
    const clap_plugin_t *plugin,
    clap_gui_resize_hints_t *hints
) {
    (void)plugin;
    (void)hints;
    return false;
}

static bool gui_adjust_size(
    const clap_plugin_t *plugin,
    uint32_t *width,
    uint32_t *height
) {
    (void)plugin;
    return *width > 0 && *height > 0;
}

static bool gui_set_size(
    const clap_plugin_t *plugin,
    uint32_t width,
    uint32_t height
) {
    fixture_plugin_t *self = fixture(plugin);
    if (width == 0 || height == 0) {
        return false;
    }
    if (getenv("YABRIDGE_FIXTURE_ADJUST") != NULL) {
        width += 7;
        height += 9;
    }
    if (self->resize_worker_started) {
        pthread_join(self->resize_worker, NULL);
        self->resize_worker_started = false;
    }
    self->width = width;
    self->height = height;
    if (getenv("YABRIDGE_FIXTURE_ASYNC_RESIZE") != NULL) {
        if (pthread_create(
                &self->resize_worker, NULL, async_resize_worker, self
            ) != 0) {
            return false;
        }
        self->resize_worker_started = true;
    } else {
        apply_resize(self);
    }
    return true;
}

static bool gui_set_parent(
    const clap_plugin_t *plugin,
    const clap_window_t *parent
) {
    fixture_plugin_t *self = fixture(plugin);
    if (parent == NULL || parent->api == NULL ||
        strcmp(parent->api, CLAP_WINDOW_API_X11) != 0 || parent->x11 == None) {
        return false;
    }
    self->display = XOpenDisplay(NULL);
    if (self->display == NULL) {
        return false;
    }
    self->parent = parent->x11;
    if (getenv("YABRIDGE_FIXTURE_DELAY_CHILDREN") == NULL &&
        !create_hierarchy(self)) {
        return false;
    }
    if (pthread_create(&self->worker, NULL, request_callback_worker, self) != 0) {
        return false;
    }
    self->worker_started = true;
    return true;
}

static bool gui_set_transient(
    const clap_plugin_t *plugin,
    const clap_window_t *window
) {
    (void)plugin;
    (void)window;
    return false;
}

static void gui_suggest_title(const clap_plugin_t *plugin, const char *title) {
    (void)plugin;
    (void)title;
}

static bool gui_show(const clap_plugin_t *plugin) {
    fixture_plugin_t *self = fixture(plugin);
    return self->display != NULL &&
           (self->wine == None || XMapWindow(self->display, self->wine) != 0);
}

static bool gui_hide(const clap_plugin_t *plugin) {
    fixture_plugin_t *self = fixture(plugin);
    return self->display != NULL && XUnmapWindow(self->display, self->wine) != 0;
}

static const clap_plugin_gui_t gui_extension = {
    .is_api_supported = gui_is_api_supported,
    .get_preferred_api = gui_get_preferred_api,
    .create = gui_create,
    .destroy = gui_destroy,
    .set_scale = gui_set_scale,
    .get_size = gui_get_size,
    .can_resize = gui_can_resize,
    .get_resize_hints = gui_get_resize_hints,
    .adjust_size = gui_adjust_size,
    .set_size = gui_set_size,
    .set_parent = gui_set_parent,
    .set_transient = gui_set_transient,
    .suggest_title = gui_suggest_title,
    .show = gui_show,
    .hide = gui_hide,
};

static const void *plugin_get_extension(
    const clap_plugin_t *plugin,
    const char *identifier
) {
    (void)plugin;
    return strcmp(identifier, CLAP_EXT_GUI) == 0 ? &gui_extension : NULL;
}

static void plugin_on_main_thread(const clap_plugin_t *plugin) {
    (void)plugin;
}

static const char *const features[] = {NULL};

static const clap_plugin_descriptor_t descriptor = {
    .clap_version = CLAP_VERSION,
    .id = "org.yabridge.native-fixture",
    .name = "Native CLAP hierarchy fixture",
    .vendor = "yabridge-test-infra",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "1",
    .description = "X11 hierarchy and callback fixture",
    .features = features,
};

static uint32_t factory_count(const clap_plugin_factory_t *factory) {
    (void)factory;
    return 1;
}

static const clap_plugin_descriptor_t *factory_descriptor(
    const clap_plugin_factory_t *factory,
    uint32_t index
) {
    (void)factory;
    return index == 0 ? &descriptor : NULL;
}

static const clap_plugin_t *factory_create(
    const clap_plugin_factory_t *factory,
    const clap_host_t *host,
    const char *plugin_id
) {
    (void)factory;
    if (host == NULL || plugin_id == NULL || strcmp(plugin_id, descriptor.id) != 0) {
        return NULL;
    }
    fixture_plugin_t *self = calloc(1, sizeof(*self));
    if (self == NULL) {
        return NULL;
    }
    self->host = host;
    self->width = 320;
    self->height = 200;
    self->plugin.desc = &descriptor;
    self->plugin.plugin_data = self;
    self->plugin.init = plugin_init;
    self->plugin.destroy = plugin_destroy;
    self->plugin.activate = plugin_activate;
    self->plugin.deactivate = plugin_deactivate;
    self->plugin.start_processing = plugin_start_processing;
    self->plugin.stop_processing = plugin_stop_processing;
    self->plugin.reset = plugin_reset;
    self->plugin.process = plugin_process;
    self->plugin.get_extension = plugin_get_extension;
    self->plugin.on_main_thread = plugin_on_main_thread;
    return &self->plugin;
}

static const clap_plugin_factory_t factory = {
    .get_plugin_count = factory_count,
    .get_plugin_descriptor = factory_descriptor,
    .create_plugin = factory_create,
};

static bool entry_init(const char *path) {
    return path != NULL && XInitThreads() != 0;
}

static void entry_deinit(void) {}

static const void *entry_get_factory(const char *identifier) {
    return strcmp(identifier, CLAP_PLUGIN_FACTORY_ID) == 0 ? &factory : NULL;
}

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
    .clap_version = CLAP_VERSION,
    .init = entry_init,
    .deinit = entry_deinit,
    .get_factory = entry_get_factory,
};
