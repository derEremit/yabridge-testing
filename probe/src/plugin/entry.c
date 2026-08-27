#include "plugin.h"

#include <stdlib.h>
#include <string.h>

#include <clap/factory/plugin-factory.h>
#include <clap/plugin-features.h>

static const char *const features[] = {CLAP_PLUGIN_FEATURE_UTILITY, NULL};

static const clap_plugin_descriptor_t descriptor = {
    .clap_version = CLAP_VERSION,
    .id = "org.yabridge.coordprobe",
    .name = "yabridge coordinate probe",
    .vendor = "yabridge-test-infra",
    .url = "https://github.com/yabridge/yabridge-test-infra",
    .manual_url = "",
    .support_url = "",
    .version = "1",
    .description = "Deterministic Win32 coordinate probe",
    .features = features,
};

static bool plugin_init(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}

static void plugin_destroy(const clap_plugin_t *plugin) {
    coordprobe_plugin_t *self = (coordprobe_plugin_t *)plugin->plugin_data;
    if (self->window != NULL) {
        coordprobe_gui_extension.destroy(plugin);
    }
    free(self);
}

static bool plugin_activate(
    const clap_plugin_t *plugin,
    double sample_rate,
    uint32_t min_frames_count,
    uint32_t max_frames_count
) {
    (void)plugin;
    (void)sample_rate;
    (void)min_frames_count;
    (void)max_frames_count;
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

static const void *plugin_get_extension(const clap_plugin_t *plugin, const char *id) {
    (void)plugin;
    if (strcmp(id, CLAP_EXT_GUI) == 0) {
        return &coordprobe_gui_extension;
    }
    return NULL;
}

static void plugin_on_main_thread(const clap_plugin_t *plugin) {
    (void)plugin;
}

static uint32_t factory_get_plugin_count(const clap_plugin_factory_t *factory) {
    (void)factory;
    return 1;
}

static const clap_plugin_descriptor_t *factory_get_plugin_descriptor(
    const clap_plugin_factory_t *factory,
    uint32_t index
) {
    (void)factory;
    return index == 0 ? &descriptor : NULL;
}

static const clap_plugin_t *factory_create_plugin(
    const clap_plugin_factory_t *factory,
    const clap_host_t *host,
    const char *plugin_id
) {
    coordprobe_plugin_t *self;
    (void)factory;
    if (host == NULL || plugin_id == NULL || strcmp(plugin_id, descriptor.id) != 0 ||
        !clap_version_is_compatible(host->clap_version)) {
        return NULL;
    }
    self = calloc(1, sizeof(*self));
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

static const clap_plugin_factory_t plugin_factory = {
    .get_plugin_count = factory_get_plugin_count,
    .get_plugin_descriptor = factory_get_plugin_descriptor,
    .create_plugin = factory_create_plugin,
};

static bool entry_init(const char *plugin_path) {
    return plugin_path != NULL;
}

static void entry_deinit(void) {}

static const void *entry_get_factory(const char *factory_id) {
    if (strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0) {
        return &plugin_factory;
    }
    return NULL;
}

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
    .clap_version = CLAP_VERSION,
    .init = entry_init,
    .deinit = entry_deinit,
    .get_factory = entry_get_factory,
};
