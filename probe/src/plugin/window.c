#include "plugin.h"

#include <stdio.h>
#include <windows.h>

static const char window_class_name[] = "YabridgeCoordProbeWindow";
static SRWLOCK window_class_lock = SRWLOCK_INIT;
static HINSTANCE window_instance = NULL;
static unsigned int window_count = 0;

static LRESULT CALLBACK coordprobe_window_proc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam
) {
    switch (message) {
    case WM_APP_CONNECTED:
        coordprobe_report_hello(window);
        coordprobe_report_attached(window);
        coordprobe_report_origin(window);
        coordprobe_report_size(window);
        return 0;
    case WM_APP_MARK:
        coordprobe_report_mark((const char *)lparam);
        HeapFree(GetProcessHeap(), 0, (void *)lparam);
        return 0;
    case WM_APP_QUERY_ORIGIN:
        coordprobe_report_origin(window);
        return 0;
    case WM_APP_REPORT_ERROR:
        coordprobe_report_error((const char *)lparam);
        HeapFree(GetProcessHeap(), 0, (void *)lparam);
        return 0;
    case WM_MOUSEMOVE:
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
        coordprobe_report_mouse(window, message, wparam, lparam);
        return 0;
    case WM_SIZE:
        coordprobe_report_size(window);
        return 0;
    default:
        return DefWindowProcA(window, message, wparam, lparam);
    }
}

HWND coordprobe_window_create(HWND parent, uint32_t width, uint32_t height) {
    WNDCLASSEXA window_class;
    HWND window;
    AcquireSRWLockExclusive(&window_class_lock);
    if (window_count == 0) {
        HMODULE module = NULL;
        if (!GetModuleHandleExA(
                GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                window_class_name,
                &module
            )) {
            fprintf(stderr, "coordprobe: could not identify probe DLL instance\n");
            ReleaseSRWLockExclusive(&window_class_lock);
            return NULL;
        }
        window_instance = (HINSTANCE)module;
        ZeroMemory(&window_class, sizeof(window_class));
        window_class.cbSize = sizeof(window_class);
        window_class.lpfnWndProc = coordprobe_window_proc;
        window_class.hInstance = window_instance;
        window_class.hCursor = LoadCursorA(NULL, IDC_ARROW);
        window_class.lpszClassName = window_class_name;
        if (!RegisterClassExA(&window_class)) {
            fprintf(
                stderr,
                "coordprobe: RegisterClassEx failed with error %lu\n",
                GetLastError()
            );
            window_instance = NULL;
            ReleaseSRWLockExclusive(&window_class_lock);
            return NULL;
        }
    }
    window = CreateWindowExA(
        0,
        window_class_name,
        "coordprobe",
        WS_CHILD | WS_VISIBLE,
        0,
        0,
        (int)width,
        (int)height,
        parent,
        NULL,
        window_instance,
        NULL
    );
    if (window == NULL) {
        fprintf(stderr, "coordprobe: CreateWindowEx failed with error %lu\n", GetLastError());
        if (window_count == 0) {
            UnregisterClassA(window_class_name, window_instance);
            window_instance = NULL;
        }
        ReleaseSRWLockExclusive(&window_class_lock);
        return NULL;
    }
    ++window_count;
    ReleaseSRWLockExclusive(&window_class_lock);
    return window;
}

void coordprobe_window_destroy(HWND window) {
    if (window == NULL) {
        return;
    }
    AcquireSRWLockExclusive(&window_class_lock);
    if (!DestroyWindow(window)) {
        fprintf(stderr, "coordprobe: DestroyWindow failed with error %lu\n", GetLastError());
        ReleaseSRWLockExclusive(&window_class_lock);
        return;
    }
    if (window_count > 0) {
        --window_count;
    }
    if (window_count == 0 && window_instance != NULL) {
        if (!UnregisterClassA(window_class_name, window_instance)) {
            fprintf(
                stderr,
                "coordprobe: UnregisterClass failed with error %lu\n",
                GetLastError()
            );
        }
        window_instance = NULL;
    }
    ReleaseSRWLockExclusive(&window_class_lock);
}
