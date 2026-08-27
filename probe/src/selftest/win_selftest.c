#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>

#include <clap/clap.h>
#include <clap/ext/gui.h>
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
    (void)host;
}

static const clap_host_t host = {
    .clap_version = CLAP_VERSION,
    .host_data = NULL,
    .name = "coordprobe pure-Wine baseline",
    .vendor = "yabridge-test-infra",
    .url = "https://github.com/yabridge/yabridge-test-infra",
    .version = "1",
    .get_extension = host_get_extension,
    .request_restart = host_request_restart,
    .request_process = host_request_process,
    .request_callback = host_request_callback,
};

static LRESULT CALLBACK parent_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcA(window, message, wparam, lparam);
}

static HWND create_parent(void) {
    static const char class_name[] = "CoordProbeSelftestParent";
    WNDCLASSEXA window_class;
    HINSTANCE instance = GetModuleHandleA(NULL);
    ZeroMemory(&window_class, sizeof(window_class));
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = parent_proc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    window_class.hCursor = LoadCursorA(NULL, IDC_ARROW);
    if (!RegisterClassExA(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return NULL;
    }
    return CreateWindowExA(
        0,
        class_name,
        "coordprobe baseline",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        180,
        140,
        400,
        300,
        NULL,
        NULL,
        instance,
        NULL
    );
}

static int run_cycle(const char *plugin_path, DWORD run_time_ms) {
    HMODULE module = NULL;
    const clap_plugin_entry_t *entry = NULL;
    const clap_plugin_factory_t *factory = NULL;
    const clap_plugin_t *plugin = NULL;
    const clap_plugin_gui_t *gui = NULL;
    HWND parent = NULL;
    clap_window_t clap_parent;
    DWORD deadline;
    int result = 1;
    bool entry_initialized = false;
    bool plugin_initialized = false;
    bool gui_created = false;

    module = LoadLibraryA(plugin_path);
    if (module == NULL) {
        fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError());
        goto cleanup;
    }
    entry = (const clap_plugin_entry_t *)GetProcAddress(module, "clap_entry");
    if (entry == NULL || !clap_version_is_compatible(entry->clap_version) ||
        !entry->init(plugin_path)) {
        fprintf(stderr, "invalid CLAP entry\n");
        goto cleanup;
    }
    entry_initialized = true;
    factory = entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
    if (factory == NULL || factory->get_plugin_count(factory) != 1) {
        fprintf(stderr, "missing CLAP factory\n");
        goto cleanup;
    }
    plugin = factory->create_plugin(factory, &host, "org.yabridge.coordprobe");
    if (plugin == NULL || !plugin->init(plugin)) {
        fprintf(stderr, "plugin initialization failed\n");
        goto cleanup;
    }
    plugin_initialized = true;
    gui = plugin->get_extension(plugin, CLAP_EXT_GUI);
    if (gui == NULL || !gui->is_api_supported(plugin, CLAP_WINDOW_API_WIN32, false) ||
        !gui->create(plugin, CLAP_WINDOW_API_WIN32, false)) {
        fprintf(stderr, "Win32 CLAP GUI unavailable\n");
        goto cleanup;
    }
    gui_created = true;
    parent = create_parent();
    if (parent == NULL) {
        fprintf(stderr, "parent window creation failed: %lu\n", GetLastError());
        goto cleanup;
    }
    ZeroMemory(&clap_parent, sizeof(clap_parent));
    clap_parent.api = CLAP_WINDOW_API_WIN32;
    clap_parent.win32 = parent;
    if (!gui->set_parent(plugin, &clap_parent)) {
        fprintf(stderr, "CLAP set_parent failed\n");
        goto cleanup;
    }
    gui->show(plugin);

    deadline = GetTickCount() + run_time_ms;
    while ((LONG)(deadline - GetTickCount()) > 0) {
        MSG message;
        while (PeekMessageA(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                goto cleanup;
            }
            TranslateMessage(&message);
            DispatchMessageA(&message);
        }
        Sleep(5);
    }
    result = 0;

cleanup:
    if (gui_created) {
        gui->hide(plugin);
        gui->destroy(plugin);
    }
    if (plugin_initialized) {
        plugin->destroy(plugin);
    }
    if (parent != NULL) {
        DestroyWindow(parent);
    }
    if (entry_initialized) {
        entry->deinit();
    }
    if (module != NULL) {
        FreeLibrary(module);
    }
    return result;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        fprintf(
            stderr,
            "usage: coordprobe-selftest.exe PLUGIN "
            "[--create-failure-recovery|--timeout-restart]\n"
        );
        return 2;
    }
    if (argc == 3) {
        if (strcmp(argv[2], "--create-failure-recovery") == 0) {
            if (run_cycle(argv[1], 0) == 0) {
                fprintf(stderr, "forced thread-creation failure unexpectedly succeeded\n");
                return 1;
            }
            SetEnvironmentVariableA("YABRIDGE_PROBE_TEST_HOOK", NULL);
            if (run_cycle(argv[1], 250) != 0) {
                fprintf(stderr, "post-thread-creation-failure recovery failed\n");
                return 1;
            }
            return 0;
        }
        if (strcmp(argv[2], "--timeout-restart") != 0) {
            fprintf(stderr, "unknown selftest mode: %s\n", argv[2]);
            return 2;
        }
        if (run_cycle(argv[1], 250) != 0) {
            fprintf(stderr, "initial timeout lifecycle cycle failed\n");
            return 1;
        }
        if (run_cycle(argv[1], 0) == 0) {
            fprintf(stderr, "restart unexpectedly succeeded while worker was live\n");
            return 1;
        }
        Sleep(2500);
        SetEnvironmentVariableA("YABRIDGE_PROBE_TEST_HOOK", NULL);
        if (run_cycle(argv[1], 250) != 0) {
            fprintf(stderr, "post-timeout lifecycle restart failed\n");
            return 1;
        }
        return 0;
    }
    for (int cycle = 0; cycle < 2; ++cycle) {
        if (run_cycle(argv[1], 5000) != 0) {
            fprintf(stderr, "coordprobe lifecycle cycle %d failed\n", cycle + 1);
            return 1;
        }
    }
    return 0;
}
