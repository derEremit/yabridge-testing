#ifndef COORDPROBE_JSONL_H
#define COORDPROBE_JSONL_H

#include <stdbool.h>
#include <stddef.h>
#include <winsock2.h>

bool probe_send_all(SOCKET socket, const char *data, size_t length);
size_t probe_escape_json(char *output, size_t capacity, const char *input);

#endif
