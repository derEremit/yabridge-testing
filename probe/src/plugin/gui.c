#include "plugin.h"

#include <string.h>

static coordprobe_plugin_t *instance(const clap_plugin_t *plugin) {
    return (coordprobe_plugin_t *)plugin->plugin_data;
}

static bool gui_is_api_supported(
    const clap_plugin_t *plugin,
    const char *api,
    bool is_floating
) {
    (void)plugin;
    return !is_floating && api != NULL && strcmp(api, CLAP_WINDOW_API_WIN32) == 0;
}

static bool gui_get_preferred_api(
    const clap_plugin_t *plugin,
    const char **api,
    bool *is_floating
) {
    (void)plugin;
    *api = CLAP_WINDOW_API_WIN32;
    *is_floating = false;
    return true;
}

static bool gui_create(const clap_plugin_t *plugin, const char *api, bool is_floating) {
    return gui_is_api_supported(plugin, api, is_floating);
}

static void gui_destroy(const clap_plugin_t *plugin) {
    coordprobe_plugin_t *self = instance(plugin);
    if (self->window != NULL) {
        coordprobe_report_stop(self->window);
        coordprobe_window_destroy(self->window);
        self->window = NULL;
    }
}

static bool gui_set_scale(const clap_plugin_t *plugin, double scale) {
    (void)plugin;
    (void)scale;
    return false;
}

static bool gui_get_size(const clap_plugin_t *plugin, uint32_t *width, uint32_t *height) {
    coordprobe_plugin_t *self = instance(plugin);
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

static bool gui_adjust_size(const clap_plugin_t *plugin, uint32_t *width, uint32_t *height) {
    (void)plugin;
    return *width > 0 && *height > 0;
}

static bool gui_set_size(const clap_plugin_t *plugin, uint32_t width, uint32_t height) {
    coordprobe_plugin_t *self = instance(plugin);
    if (width == 0 || height == 0) {
        return false;
    }
    self->width = width;
    self->height = height;
    if (self->window != NULL) {
        return SetWindowPos(
                   self->window,
                   NULL,
                   0,
                   0,
                   (int)width,
                   (int)height,
                   SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
               ) != 0;
    }
    return true;
}

static bool gui_set_parent(const clap_plugin_t *plugin, const clap_window_t *parent) {
    coordprobe_plugin_t *self = instance(plugin);
    if (parent == NULL || parent->api == NULL ||
        strcmp(parent->api, CLAP_WINDOW_API_WIN32) != 0 || parent->win32 == NULL ||
        self->window != NULL) {
        return false;
    }
    self->window = coordprobe_window_create((HWND)parent->win32, self->width, self->height);
    if (self->window == NULL) {
        return false;
    }
    if (!coordprobe_report_start(self->window)) {
        coordprobe_window_destroy(self->window);
        self->window = NULL;
        return false;
    }
    return true;
}

static bool gui_set_transient(const clap_plugin_t *plugin, const clap_window_t *window) {
    (void)plugin;
    (void)window;
    return false;
}

static void gui_suggest_title(const clap_plugin_t *plugin, const char *title) {
    (void)plugin;
    (void)title;
}

static bool gui_show(const clap_plugin_t *plugin) {
    coordprobe_plugin_t *self = instance(plugin);
    if (self->window == NULL) {
        return false;
    }
    ShowWindow(self->window, SW_SHOW);
    return true;
}

static bool gui_hide(const clap_plugin_t *plugin) {
    coordprobe_plugin_t *self = instance(plugin);
    if (self->window == NULL) {
        return false;
    }
    ShowWindow(self->window, SW_HIDE);
    return true;
}

const clap_plugin_gui_t coordprobe_gui_extension = {
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
