#ifndef COORDPROBE_PLUGIN_H
#define COORDPROBE_PLUGIN_H

#include <stdbool.h>
#include <stdint.h>
#include <winsock2.h>
#include <windows.h>

#include <clap/clap.h>
#include <clap/ext/gui.h>

#define WM_APP_CONNECTED (WM_APP + 1)
#define WM_APP_MARK (WM_APP + 2)
#define WM_APP_QUERY_ORIGIN (WM_APP + 3)
#define WM_APP_REPORT_ERROR (WM_APP + 4)

typedef struct coordprobe_plugin {
    clap_plugin_t plugin;
    const clap_host_t *host;
    HWND window;
    uint32_t width;
    uint32_t height;
} coordprobe_plugin_t;

extern const clap_plugin_gui_t coordprobe_gui_extension;

HWND coordprobe_window_create(HWND parent, uint32_t width, uint32_t height);
void coordprobe_window_destroy(HWND window);

bool coordprobe_report_start(HWND window);
void coordprobe_report_stop(HWND window);
void coordprobe_report_hello(HWND window);
void coordprobe_report_attached(HWND window);
void coordprobe_report_mouse(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
void coordprobe_report_mark(const char *label);
void coordprobe_report_origin(HWND window);
void coordprobe_report_size(HWND window);
void coordprobe_report_error(const char *message);

#endif
