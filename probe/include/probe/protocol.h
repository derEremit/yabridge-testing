#ifndef COORDPROBE_PROTOCOL_H
#define COORDPROBE_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PROBE_MAX_LINE 65536
#define PROBE_MAX_TOKEN 128
#define PROBE_MAX_LABEL 256

bool probe_json_string(const char *json, const char *key, char *value, size_t capacity);
bool probe_json_integer(const char *json, const char *key, int64_t *value);

#endif
