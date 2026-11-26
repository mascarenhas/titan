#ifndef TITAN_BROWSER_TRACE_H
#define TITAN_BROWSER_TRACE_H

#include <stdint.h>

#define TITAN_BROWSER_TRACE_CAPACITY 512u
#define TITAN_BROWSER_TRACE_HEADROOM 128u
#define TITAN_BROWSER_TRACE_FILE_BYTES 256u
#define TITAN_BROWSER_TRACE_SYMBOL_BYTES 256u
#define TITAN_BROWSER_TRACE_TRUNCATED 1u
#define TITAN_BROWSER_TRACE_HAS_PC 1u
#define TITAN_BROWSER_TRACE_HAS_FUNCTION_INDEX 2u
#define TITAN_BROWSER_TRACE_ENTRY 4u

/* Private Wasm32 adapter ABI: little-endian words, record stride 12 bytes. */
typedef struct {
    uint32_t pc;
    uint32_t function_index;
    uint32_t flags;
} TitanBrowserTraceRecord;

typedef struct {
    uint32_t count;
    uint32_t flags;
    TitanBrowserTraceRecord records[TITAN_BROWSER_TRACE_CAPACITY];
} TitanBrowserTraceBuffer;

/* Host imports. This header stands alone, without titan/ffi.h's
 * TITAN_WASM_IMPORT, because adapter units compile it by itself. */
/* Capture: 0 OK, 1 map unavailable, 2 capture failed. */
__attribute__((import_module("env"), import_name("titan_browser_trace_capture")))
int titan_browser_trace_capture(TitanBrowserTraceBuffer *out, uint32_t capacity);
/* Symbolize: 0 unknown/no-line, 1 resolved, 2 symbolization failed. */
__attribute__((import_module("env"), import_name("titan_browser_trace_symbolize")))
int titan_browser_trace_symbolize(const TitanBrowserTraceRecord *record,
    char *base, uint32_t base_bytes, char *symbol, uint32_t symbol_bytes,
    uint32_t *line);

#endif
