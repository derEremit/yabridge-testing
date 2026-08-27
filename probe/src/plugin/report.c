#include "plugin.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windowsx.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <probe/protocol.h>

#include "../common/jsonl.h"

static SOCKET report_socket = INVALID_SOCKET;
static HANDLE report_thread = NULL;
static HMODULE report_lifecycle_module = NULL;
static volatile LONG report_stopping = 0;
static volatile LONG report_seq = -1;
static volatile LONG report_send_failed = 0;
static volatile LONG report_worker_stage = 0;
static LONG report_generation = 0;
static SRWLOCK report_lock = SRWLOCK_INIT;
static char report_token[PROBE_MAX_TOKEN];
static char report_endpoint[128];

typedef struct report_worker_context {
    HMODULE module;
    HWND window;
    LONG generation;
    char endpoint[sizeof(report_endpoint)];
    char token[PROBE_MAX_TOKEN];
} report_worker_context_t;

#ifdef COORDPROBE_TEST_HOOKS
static LONG test_send_failure_forced = 0;

static bool test_hook_enabled(const char *name) {
    char value[64];
    DWORD length = GetEnvironmentVariableA(
        "YABRIDGE_PROBE_TEST_HOOK",
        value,
        sizeof(value)
    );
    return length > 0 && length < sizeof(value) && strcmp(value, name) == 0;
}
#endif

static void report_diagnostic(const char *message) {
    fprintf(stderr, "coordprobe: %s\n", message);
}

static void report_socket_error(const char *operation, int error) {
    fprintf(stderr, "coordprobe: %s failed with Winsock error %d\n", operation, error);
}

static bool report_fields(const char *type, const char *fields) {
    char escaped_token[PROBE_MAX_TOKEN * 2];
    char line[4096];
    LONG seq;
    int length;
    bool sent;
    AcquireSRWLockExclusive(&report_lock);
    if (report_socket == INVALID_SOCKET) {
        ReleaseSRWLockExclusive(&report_lock);
        return false;
    }
    if (probe_escape_json(escaped_token, sizeof(escaped_token), report_token) == 0) {
        report_diagnostic("authentication token could not be encoded");
        ReleaseSRWLockExclusive(&report_lock);
        return false;
    }
    seq = InterlockedIncrement(&report_seq);
    length = snprintf(
        line,
        sizeof(line),
        "{\"v\":1,\"seq\":%ld,\"type\":\"%s\",\"token\":\"%s\"%s}\n",
        seq,
        type,
        escaped_token,
        fields
    );
    if (length <= 0 || (size_t)length >= sizeof(line)) {
        report_diagnostic("protocol message exceeds 4095-byte limit");
        ReleaseSRWLockExclusive(&report_lock);
        return false;
    }
#ifdef COORDPROBE_TEST_HOOKS
    if (test_hook_enabled("fail_send") &&
        InterlockedCompareExchange(&test_send_failure_forced, 1, 0) == 0) {
        WSASetLastError(WSAECONNRESET);
        sent = false;
    } else {
        sent = probe_send_all(report_socket, line, (size_t)length);
    }
#else
    sent = probe_send_all(report_socket, line, (size_t)length);
#endif
    if (!sent && InterlockedCompareExchange(&report_send_failed, 1, 0) == 0) {
        report_socket_error("protocol send", WSAGetLastError());
        shutdown(report_socket, SD_BOTH);
    }
    ReleaseSRWLockExclusive(&report_lock);
    return sent;
}

static void post_text(HWND window, UINT message, const char *text) {
    size_t length = strlen(text) + 1;
    char *copy = HeapAlloc(GetProcessHeap(), 0, length);
    if (copy == NULL) {
        return;
    }
    memcpy(copy, text, length);
    if (!PostMessageA(window, message, 0, (LPARAM)copy)) {
        HeapFree(GetProcessHeap(), 0, copy);
    }
}

static bool valid_command(
    const char *line,
    const char *expected_token,
    char *type,
    size_t type_size
) {
    char token[PROBE_MAX_TOKEN];
    int64_t version;
    int64_t seq;
    return probe_json_integer(line, "v", &version) && version == 1 &&
           probe_json_integer(line, "seq", &seq) && seq >= 0 &&
           probe_json_string(line, "type", type, type_size) &&
           probe_json_string(line, "token", token, sizeof(token)) &&
           strcmp(token, expected_token) == 0;
}

static void handle_command(HWND window, const char *expected_token, char *line) {
    char type[32];
    if (!valid_command(line, expected_token, type, sizeof(type))) {
        post_text(window, WM_APP_REPORT_ERROR, "invalid command envelope");
        return;
    }
    if (strcmp(type, "mark") == 0) {
        char label[PROBE_MAX_LABEL];
        if (!probe_json_string(line, "label", label, sizeof(label))) {
            post_text(window, WM_APP_REPORT_ERROR, "mark missing label");
            return;
        }
        post_text(window, WM_APP_MARK, label);
    } else if (strcmp(type, "origin") == 0) {
        PostMessageA(window, WM_APP_QUERY_ORIGIN, 0, 0);
    } else {
        post_text(window, WM_APP_REPORT_ERROR, "unsupported command");
    }
}

static void worker_close_socket(SOCKET socket, LONG generation) {
    AcquireSRWLockExclusive(&report_lock);
    if (report_generation == generation && report_socket == socket) {
        report_socket = INVALID_SOCKET;
        closesocket(socket);
    }
    ReleaseSRWLockExclusive(&report_lock);
}

static void worker_exit(HMODULE module, SOCKET socket, LONG generation, DWORD status) {
    InterlockedExchange(&report_worker_stage, 4);
    if (socket != INVALID_SOCKET) {
        worker_close_socket(socket, generation);
    }
    InterlockedExchange(&report_worker_stage, 5);
    WSACleanup();
    if (module != NULL) {
        FreeLibraryAndExitThread(module, status);
    }
    ExitThread(status);
}

static bool connect_with_timeout(SOCKET socket, const struct sockaddr_in *address) {
    u_long nonblocking = 1;
    fd_set writable;
    fd_set errors;
    struct timeval timeout = {2, 0};
    int socket_error = 0;
    int socket_error_size = sizeof(socket_error);
    int selected;
    if (ioctlsocket(socket, FIONBIO, &nonblocking) == SOCKET_ERROR) {
        report_socket_error("setting nonblocking connect", WSAGetLastError());
        return false;
    }
    if (connect(socket, (const struct sockaddr *)address, sizeof(*address)) == 0) {
        return true;
    }
    if (WSAGetLastError() != WSAEWOULDBLOCK) {
        report_socket_error("connect", WSAGetLastError());
        return false;
    }
    FD_ZERO(&writable);
    FD_ZERO(&errors);
    FD_SET(socket, &writable);
    FD_SET(socket, &errors);
    selected = select(0, NULL, &writable, &errors, &timeout);
    if (selected == 0) {
        report_diagnostic("connect timed out after 2 seconds");
        return false;
    }
    if (selected == SOCKET_ERROR ||
        getsockopt(
            socket,
            SOL_SOCKET,
            SO_ERROR,
            (char *)&socket_error,
            &socket_error_size
        ) == SOCKET_ERROR ||
        socket_error != 0) {
        report_socket_error(
            "connect",
            socket_error != 0 ? socket_error : WSAGetLastError()
        );
        return false;
    }
    return true;
}

static DWORD WINAPI socket_thread(void *context) {
    report_worker_context_t *worker_context = context;
    HWND window = worker_context->window;
    HMODULE module = worker_context->module;
    LONG generation = worker_context->generation;
    WSADATA data;
    SOCKET socket = INVALID_SOCKET;
    char endpoint[sizeof(report_endpoint)];
    char token[PROBE_MAX_TOKEN];
    char *separator;
    char *end = NULL;
    unsigned long port;
    struct sockaddr_in address;
    char line[PROBE_MAX_LINE + 1];
    size_t used = 0;
    char buffer[1024];

    InterlockedExchange(&report_worker_stage, 1);
    memcpy(endpoint, worker_context->endpoint, sizeof(endpoint));
    memcpy(token, worker_context->token, sizeof(token));
    HeapFree(GetProcessHeap(), 0, worker_context);
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        report_diagnostic("WSAStartup failed");
        FreeLibraryAndExitThread(module, 1);
    }
    separator = strrchr(endpoint, ':');
    if (separator == NULL) {
        report_diagnostic("endpoint must be 127.0.0.1:PORT");
        worker_exit(module, socket, generation, 1);
    }
    *separator++ = '\0';
    port = strtoul(separator, &end, 10);
    if (strcmp(endpoint, "127.0.0.1") != 0 || *separator == '\0' || *end != '\0' ||
        port == 0 || port > 65535) {
        report_diagnostic("endpoint must be numeric loopback 127.0.0.1:PORT");
        worker_exit(module, socket, generation, 1);
    }
    if (InterlockedCompareExchange(&report_stopping, 0, 0) != 0) {
        worker_exit(module, socket, generation, 0);
    }

    socket = WSASocketA(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, 0);
    if (socket == INVALID_SOCKET) {
        report_socket_error("socket", WSAGetLastError());
        worker_exit(module, socket, generation, 1);
    }
    AcquireSRWLockExclusive(&report_lock);
    if (report_generation != generation ||
        InterlockedCompareExchange(&report_stopping, 0, 0) != 0) {
        ReleaseSRWLockExclusive(&report_lock);
        closesocket(socket);
        socket = INVALID_SOCKET;
        worker_exit(module, socket, generation, 0);
    }
    report_socket = socket;
    ReleaseSRWLockExclusive(&report_lock);
    InterlockedExchange(&report_worker_stage, 2);

    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((u_short)port);
    InetPtonA(AF_INET, endpoint, &address.sin_addr);
    if (!connect_with_timeout(socket, &address) ||
        InterlockedCompareExchange(&report_stopping, 0, 0) != 0) {
        worker_exit(module, socket, generation, 1);
    }
    PostMessageA(window, WM_APP_CONNECTED, 0, 0);
    InterlockedExchange(&report_worker_stage, 3);

    while (InterlockedCompareExchange(&report_stopping, 0, 0) == 0) {
        int received = recv(socket, buffer, sizeof(buffer), 0);
        if (received == SOCKET_ERROR) {
            int error = WSAGetLastError();
            if (error == WSAETIMEDOUT || error == WSAEWOULDBLOCK) {
                Sleep(10);
                continue;
            }
            if (InterlockedCompareExchange(&report_stopping, 0, 0) == 0) {
                report_socket_error("receive", error);
            }
            break;
        }
        if (received == 0) {
            break;
        }
        for (int index = 0; index < received; ++index) {
            char value = buffer[index];
            if (value == '\n') {
                line[used] = '\0';
                handle_command(window, token, line);
                used = 0;
            } else if (used >= PROBE_MAX_LINE) {
                used = 0;
                post_text(window, WM_APP_REPORT_ERROR, "command line exceeds 64 KiB limit");
            } else {
                line[used++] = value;
            }
        }
    }
#ifdef COORDPROBE_TEST_HOOKS
    if (test_hook_enabled("timeout_restart")) {
        report_diagnostic("test hook delaying socket worker exit");
        Sleep(5000);
    }
#endif
    worker_exit(module, socket, generation, 0);
    return 0;
}

bool coordprobe_report_start(HWND window) {
    char endpoint[sizeof(report_endpoint)] = {0};
    char token[PROBE_MAX_TOKEN] = {0};
    report_worker_context_t *worker_context;
    HMODULE module = NULL;
    HMODULE lifecycle_module = NULL;
    HANDLE thread;
    DWORD prior_worker;
    DWORD endpoint_length;
    DWORD token_length;
    endpoint_length = GetEnvironmentVariableA(
        "YABRIDGE_PROBE_ENDPOINT",
        endpoint,
        sizeof(endpoint)
    );
    token_length = GetEnvironmentVariableA(
        "YABRIDGE_PROBE_TOKEN",
        token,
        sizeof(token)
    );
    if (endpoint_length == 0) {
        report_diagnostic("missing YABRIDGE_PROBE_ENDPOINT");
        return false;
    }
    if (endpoint_length >= sizeof(endpoint)) {
        report_diagnostic("YABRIDGE_PROBE_ENDPOINT exceeds 127-byte limit");
        return false;
    }
    if (token_length == 0) {
        report_diagnostic("missing YABRIDGE_PROBE_TOKEN");
        return false;
    }
    if (token_length >= sizeof(token)) {
        report_diagnostic("YABRIDGE_PROBE_TOKEN exceeds 127-byte limit");
        return false;
    }

    AcquireSRWLockExclusive(&report_lock);
    if (report_thread != NULL) {
        prior_worker = WaitForSingleObject(report_thread, 0);
        if (prior_worker == WAIT_OBJECT_0) {
            CloseHandle(report_thread);
            report_thread = NULL;
            if (report_lifecycle_module != NULL) {
                FreeLibrary(report_lifecycle_module);
                report_lifecycle_module = NULL;
            }
            report_diagnostic("reaped completed previous worker");
        } else {
            report_diagnostic(
                prior_worker == WAIT_TIMEOUT
                    ? "refusing report restart while previous worker is running"
                    : "refusing report restart after previous worker wait failure"
            );
            ReleaseSRWLockExclusive(&report_lock);
            return false;
        }
    }
    worker_context = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*worker_context));
    if (worker_context == NULL) {
        report_diagnostic("could not allocate socket worker context");
        ReleaseSRWLockExclusive(&report_lock);
        return false;
    }
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            report_endpoint,
            &module
        )) {
        report_diagnostic("could not acquire probe DLL ownership for socket worker");
        HeapFree(GetProcessHeap(), 0, worker_context);
        ReleaseSRWLockExclusive(&report_lock);
        return false;
    }
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            report_endpoint,
            &lifecycle_module
        )) {
        report_diagnostic("could not retain probe DLL lifecycle state");
        FreeLibrary(module);
        HeapFree(GetProcessHeap(), 0, worker_context);
        ReleaseSRWLockExclusive(&report_lock);
        return false;
    }

    ++report_generation;
    memcpy(report_endpoint, endpoint, sizeof(endpoint));
    memcpy(report_token, token, sizeof(token));
    InterlockedExchange(&report_stopping, 0);
    InterlockedExchange(&report_seq, -1);
    InterlockedExchange(&report_send_failed, 0);
    InterlockedExchange(&report_worker_stage, 0);
#ifdef COORDPROBE_TEST_HOOKS
    InterlockedExchange(&test_send_failure_forced, 0);
#endif
    worker_context->module = module;
    worker_context->window = window;
    worker_context->generation = report_generation;
    memcpy(worker_context->endpoint, endpoint, sizeof(endpoint));
    memcpy(worker_context->token, token, sizeof(token));

#ifdef COORDPROBE_TEST_HOOKS
    if (test_hook_enabled("fail_create")) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        thread = NULL;
    } else {
        thread = CreateThread(NULL, 0, socket_thread, worker_context, 0, NULL);
    }
#else
    thread = CreateThread(NULL, 0, socket_thread, worker_context, 0, NULL);
#endif
    if (thread == NULL) {
        fprintf(
            stderr,
            "coordprobe: CreateThread failed with error %lu\n",
            GetLastError()
        );
        HeapFree(GetProcessHeap(), 0, worker_context);
        FreeLibrary(module);
        FreeLibrary(lifecycle_module);
        report_endpoint[0] = '\0';
        report_token[0] = '\0';
        ReleaseSRWLockExclusive(&report_lock);
        return false;
    }
    report_thread = thread;
    report_lifecycle_module = lifecycle_module;
    ReleaseSRWLockExclusive(&report_lock);
    return true;
}

void coordprobe_report_stop(HWND window) {
    HANDLE thread;
    HMODULE lifecycle_module = NULL;
    DWORD wait_result;
    (void)window;
    report_fields("bye", "");
    InterlockedExchange(&report_stopping, 1);
    AcquireSRWLockExclusive(&report_lock);
    if (report_socket != INVALID_SOCKET) {
        shutdown(report_socket, SD_BOTH);
    }
    thread = report_thread;
    ReleaseSRWLockExclusive(&report_lock);
    if (thread != NULL) {
        wait_result = WaitForSingleObject(thread, 3000);
        if (wait_result != WAIT_OBJECT_0) {
            if (wait_result == WAIT_TIMEOUT) {
                fprintf(
                    stderr,
                    "coordprobe: socket worker did not stop within 3 seconds at stage %ld; "
                    "worker retains DLL and Winsock ownership\n",
                    InterlockedCompareExchange(&report_worker_stage, 0, 0)
                );
            } else {
                fprintf(
                    stderr,
                    "coordprobe: socket worker wait failed with error %lu\n",
                    GetLastError()
                );
            }
            return;
        }
        AcquireSRWLockExclusive(&report_lock);
        if (report_thread == thread) {
            CloseHandle(report_thread);
            report_thread = NULL;
            lifecycle_module = report_lifecycle_module;
            report_lifecycle_module = NULL;
        }
        ReleaseSRWLockExclusive(&report_lock);
        if (lifecycle_module != NULL) {
            FreeLibrary(lifecycle_module);
        }
    }
}

void coordprobe_report_hello(HWND window) {
    (void)window;
    report_fields("hello", ",\"plugin_id\":\"org.yabridge.coordprobe\"");
}

void coordprobe_report_attached(HWND window) {
    char fields[96];
    snprintf(fields, sizeof(fields), ",\"hwnd\":%" PRIuPTR, (uintptr_t)window);
    report_fields("attached", fields);
}

void coordprobe_report_origin(HWND window) {
    POINT origin = {0, 0};
    char fields[160];
    ClientToScreen(window, &origin);
    snprintf(
        fields,
        sizeof(fields),
        ",\"x\":%ld,\"y\":%ld,\"virtual_x\":%d,\"virtual_y\":%d",
        origin.x,
        origin.y,
        GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN)
    );
    report_fields("origin", fields);
}

void coordprobe_report_size(HWND window) {
    RECT client;
    char fields[96];
    GetClientRect(window, &client);
    snprintf(
        fields,
        sizeof(fields),
        ",\"w\":%ld,\"h\":%ld",
        client.right - client.left,
        client.bottom - client.top
    );
    report_fields("size", fields);
}

void coordprobe_report_mouse(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    const int x = GET_X_LPARAM(lparam);
    const int y = GET_Y_LPARAM(lparam);
    POINT screen = {x, y};
    POINT cursor = {0, 0};
    POINT origin = {0, 0};
    int button = 0;
    char fields[512];
    (void)wparam;
    ClientToScreen(window, &screen);
    ClientToScreen(window, &origin);
    GetCursorPos(&cursor);
    if (message == WM_LBUTTONDOWN || message == WM_LBUTTONUP) {
        button = 1;
    } else if (message == WM_MBUTTONDOWN || message == WM_MBUTTONUP) {
        button = 2;
    } else if (message == WM_RBUTTONDOWN || message == WM_RBUTTONUP) {
        button = 3;
    }
    snprintf(
        fields,
        sizeof(fields),
        ",\"x\":%d,\"y\":%d,\"message\":%u,\"button\":%d,"
        "\"client_x\":%d,\"client_y\":%d,\"screen_x\":%ld,\"screen_y\":%ld,"
        "\"cursor_x\":%ld,\"cursor_y\":%ld,\"origin_x\":%ld,\"origin_y\":%ld,"
        "\"virtual_x\":%d,\"virtual_y\":%d",
        x,
        y,
        message,
        button,
        x,
        y,
        screen.x,
        screen.y,
        cursor.x,
        cursor.y,
        origin.x,
        origin.y,
        GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN)
    );
    report_fields("mouse", fields);
}

void coordprobe_report_mark(const char *label) {
    char escaped[PROBE_MAX_LABEL * 2];
    char fields[PROBE_MAX_LABEL * 2 + 32];
    if (probe_escape_json(escaped, sizeof(escaped), label) == 0) {
        coordprobe_report_error("mark label too long");
        return;
    }
    snprintf(fields, sizeof(fields), ",\"label\":\"%s\"", escaped);
    report_fields("mark", fields);
}

void coordprobe_report_error(const char *message) {
    char escaped[512];
    char fields[560];
    if (probe_escape_json(escaped, sizeof(escaped), message) == 0) {
        return;
    }
    snprintf(fields, sizeof(fields), ",\"message\":\"%s\"", escaped);
    report_fields("error", fields);
}
