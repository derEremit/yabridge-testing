#include "host.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <clap/factory/plugin-factory.h>

static const void *host_get_extension(const clap_host_t *host, const char *extension_id) {
    (void)host;
    (void)extension_id;
    return NULL;
}

static void host_request_restart(const clap_host_t *host) {
    (void)host;
}

static void host_request_process(const clap_host_t *host) {
    (void)host;
}

static void host_request_callback(const clap_host_t *host) {
    probe_host_t *state = host->host_data;
    const unsigned char wakeup = 1;
    pthread_mutex_lock(&state->callback_mutex);
    bool needs_wakeup = !state->callback_pending;
    state->callback_pending = true;
    pthread_mutex_unlock(&state->callback_mutex);
    if (needs_wakeup && state->callback_pipe[1] >= 0) {
        ssize_t written = write(state->callback_pipe[1], &wakeup, sizeof(wakeup));
        if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            fprintf(stderr, "clap-probe-host: callback wakeup write failed: %s\n", strerror(errno));
        }
    }
}

static bool load_entry(
    probe_host_t *host,
    const char *path,
    char *error,
    size_t error_size
) {
    void *symbol;
    host->module = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (host->module == NULL) {
        snprintf(error, error_size, "dlopen failed: %s", dlerror());
        return false;
    }
    dlerror();
    symbol = dlsym(host->module, "clap_entry");
    const char *dynamic_error = dlerror();
    if (dynamic_error != NULL || symbol == NULL) {
        snprintf(
            error,
            error_size,
            "dlsym(clap_entry) failed: %s",
            dynamic_error != NULL ? dynamic_error : "null symbol"
        );
        return false;
    }
    memcpy(&host->entry, &symbol, sizeof(host->entry));
    if (!clap_version_is_compatible(host->entry->clap_version)) {
        snprintf(error, error_size, "plugin uses an incompatible CLAP version");
        return false;
    }
    if (!host->entry->init(path)) {
        snprintf(error, error_size, "clap_entry.init rejected plugin path");
        return false;
    }
    host->entry_initialized = true;
    return true;
}

bool probe_clap_open(
    probe_host_t *host,
    const char *path,
    const char *plugin_id,
    char *error,
    size_t error_size
) {
    const clap_plugin_factory_t *factory;
    const clap_plugin_descriptor_t *descriptor = NULL;
    clap_window_t parent;
    if (!load_entry(host, path, error, error_size)) {
        goto fail;
    }
    factory = host->entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
    if (factory == NULL) {
        snprintf(error, error_size, "plugin does not expose the CLAP plugin factory");
        goto fail;
    }
    uint32_t count = factory->get_plugin_count(factory);
    if (count == 0) {
        snprintf(error, error_size, "CLAP factory contains no plugins");
        goto fail;
    }
    for (uint32_t index = 0; index < count; ++index) {
        const clap_plugin_descriptor_t *candidate =
            factory->get_plugin_descriptor(factory, index);
        if (candidate == NULL || candidate->id == NULL) {
            snprintf(error, error_size, "CLAP factory returned an invalid descriptor");
            goto fail;
        }
        if ((plugin_id == NULL && index == 0) ||
            (plugin_id != NULL && strcmp(candidate->id, plugin_id) == 0)) {
            descriptor = candidate;
            break;
        }
    }
    if (descriptor == NULL) {
        snprintf(error, error_size, "requested CLAP plugin id was not found");
        goto fail;
    }
    host->plugin = factory->create_plugin(factory, &host->clap_host, descriptor->id);
    if (host->plugin == NULL) {
        snprintf(error, error_size, "CLAP factory failed to create plugin");
        goto fail;
    }
    if (!host->plugin->init(host->plugin)) {
        snprintf(error, error_size, "CLAP plugin init failed");
        goto fail;
    }
    host->plugin_initialized = true;
    if (!host->plugin->activate(host->plugin, 48000.0, 64, 1024)) {
        snprintf(error, error_size, "CLAP plugin activate failed");
        goto fail;
    }
    host->plugin_activated = true;
    host->plugin_gui = host->plugin->get_extension(host->plugin, CLAP_EXT_GUI);
    if (host->plugin_gui == NULL ||
        !host->plugin_gui->is_api_supported(host->plugin, CLAP_WINDOW_API_X11, false)) {
        snprintf(error, error_size, "CLAP plugin does not support embedded X11 GUI");
        goto fail;
    }
    if (!host->plugin_gui->create(host->plugin, CLAP_WINDOW_API_X11, false)) {
        snprintf(error, error_size, "CLAP GUI create failed");
        goto fail;
    }
    host->gui_created = true;
    memset(&parent, 0, sizeof(parent));
    parent.api = CLAP_WINDOW_API_X11;
    parent.x11 = host->clap_parent;
    if (!host->plugin_gui->set_parent(host->plugin, &parent)) {
        snprintf(error, error_size, "CLAP GUI set_parent failed");
        goto fail;
    }
    if (!host->plugin_gui->show(host->plugin)) {
        snprintf(error, error_size, "CLAP GUI show failed");
        goto fail;
    }
    host->gui_shown = true;
    XSync(host->display, False);
    if (!probe_discover_plugin_chain(
            host->display,
            host->clap_parent,
            &host->wrapper,
            &host->wine_window,
            error,
            error_size
        )) {
        goto fail;
    }
    host->gui = host->wine_window;
    XSelectInput(
        host->display,
        host->gui,
        StructureNotifyMask | PointerMotionMask
    );
    if (!probe_x11_wait_mapped(host, host->gui, error, error_size)) {
        goto fail;
    }
    return true;

fail:
    probe_clap_close(host);
    return false;
}

bool probe_clap_dispatch_callback(probe_host_t *host) {
    unsigned char wakeups[64];
    ssize_t count = read(host->callback_pipe[0], wakeups, sizeof(wakeups));
    pthread_mutex_lock(&host->callback_mutex);
    bool pending = host->callback_pending;
    host->callback_pending = false;
    pthread_mutex_unlock(&host->callback_mutex);
    if (count <= 0 || !pending || host->plugin == NULL) {
        return false;
    }
    host->plugin->on_main_thread(host->plugin);
    return true;
}

void probe_clap_close(probe_host_t *host) {
    if (host->plugin != NULL && host->plugin_gui != NULL && host->gui_shown) {
        host->plugin_gui->hide(host->plugin);
        host->gui_shown = false;
    }
    if (host->plugin != NULL && host->plugin_gui != NULL && host->gui_created) {
        host->plugin_gui->destroy(host->plugin);
        host->gui_created = false;
    }
    if (host->plugin != NULL && host->plugin_activated) {
        host->plugin->deactivate(host->plugin);
        host->plugin_activated = false;
    }
    if (host->plugin != NULL) {
        host->plugin->destroy(host->plugin);
        host->plugin = NULL;
        host->plugin_initialized = false;
    }
    host->plugin_gui = NULL;
    if (host->entry != NULL && host->entry_initialized) {
        host->entry->deinit();
        host->entry_initialized = false;
    }
    host->entry = NULL;
    if (host->module != NULL) {
        dlclose(host->module);
        host->module = NULL;
    }
}

void probe_clap_host_initialize(probe_host_t *host) {
    host->clap_host.clap_version = CLAP_VERSION;
    host->clap_host.host_data = host;
    host->clap_host.name = "yabridge coordinate probe host";
    host->clap_host.vendor = "yabridge-test-infra";
    host->clap_host.url = "https://github.com/yabridge/yabridge-test-infra";
    host->clap_host.version = "1";
    host->clap_host.get_extension = host_get_extension;
    host->clap_host.request_restart = host_request_restart;
    host->clap_host.request_process = host_request_process;
    host->clap_host.request_callback = host_request_callback;
}
