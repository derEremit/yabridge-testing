#include "jsonl.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <probe/protocol.h>

bool probe_send_all(SOCKET socket, const char *data, size_t length) {
    size_t offset = 0;
    DWORD deadline = GetTickCount() + 2000;
    while (offset < length) {
        int chunk = send(socket, data + offset, (int)(length - offset), 0);
        if (chunk == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEWOULDBLOCK &&
                (LONG)(deadline - GetTickCount()) > 0) {
                fd_set writable;
                struct timeval timeout = {0, 250000};
                FD_ZERO(&writable);
                FD_SET(socket, &writable);
                if (select(0, NULL, &writable, NULL, &timeout) > 0) {
                    continue;
                }
            }
            return false;
        }
        if (chunk == 0) {
            return false;
        }
        offset += (size_t)chunk;
    }
    return true;
}

size_t probe_escape_json(char *output, size_t capacity, const char *input) {
    static const char hex[] = "0123456789abcdef";
    size_t used = 0;
    const unsigned char *cursor = (const unsigned char *)input;
    while (*cursor != '\0') {
        unsigned char value = *cursor++;
        const char *short_escape = NULL;
        if (value == '"' || value == '\\') {
            short_escape = value == '"' ? "\\\"" : "\\\\";
        } else if (value == '\n') {
            short_escape = "\\n";
        } else if (value == '\r') {
            short_escape = "\\r";
        } else if (value == '\t') {
            short_escape = "\\t";
        }
        if (short_escape != NULL) {
            if (used + 2 >= capacity) {
                return 0;
            }
            output[used++] = short_escape[0];
            output[used++] = short_escape[1];
        } else if (value < 0x20) {
            if (used + 6 >= capacity) {
                return 0;
            }
            output[used++] = '\\';
            output[used++] = 'u';
            output[used++] = '0';
            output[used++] = '0';
            output[used++] = hex[value >> 4];
            output[used++] = hex[value & 0x0f];
        } else {
            if (used + 1 >= capacity) {
                return 0;
            }
            output[used++] = (char)value;
        }
    }
    if (capacity == 0) {
        return 0;
    }
    output[used] = '\0';
    return used;
}

static const char *find_value(const char *json, const char *key) {
    char pattern[80];
    int written = snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    if (written <= 0 || (size_t)written >= sizeof(pattern)) {
        return NULL;
    }
    const char *cursor = strstr(json, pattern);
    if (cursor == NULL) {
        return NULL;
    }
    cursor += strlen(pattern);
    while (isspace((unsigned char)*cursor)) {
        ++cursor;
    }
    if (*cursor++ != ':') {
        return NULL;
    }
    while (isspace((unsigned char)*cursor)) {
        ++cursor;
    }
    return cursor;
}

bool probe_json_string(const char *json, const char *key, char *value, size_t capacity) {
    const char *cursor = find_value(json, key);
    size_t used = 0;
    if (cursor == NULL || *cursor++ != '"' || capacity == 0) {
        return false;
    }
    while (*cursor != '\0' && *cursor != '"') {
        char decoded = *cursor++;
        if (decoded == '\\') {
            char escape = *cursor++;
            if (escape == '"' || escape == '\\' || escape == '/') {
                decoded = escape;
            } else if (escape == 'n') {
                decoded = '\n';
            } else if (escape == 'r') {
                decoded = '\r';
            } else if (escape == 't') {
                decoded = '\t';
            } else {
                return false;
            }
        }
        if (used + 1 >= capacity) {
            return false;
        }
        value[used++] = decoded;
    }
    if (*cursor != '"') {
        return false;
    }
    value[used] = '\0';
    return true;
}

bool probe_json_integer(const char *json, const char *key, int64_t *value) {
    const char *cursor = find_value(json, key);
    char *end = NULL;
    if (cursor == NULL) {
        return false;
    }
    long long parsed = strtoll(cursor, &end, 10);
    if (end == cursor) {
        return false;
    }
    *value = (int64_t)parsed;
    return true;
}
