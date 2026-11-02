#include "titan-browser-trace.h"

static TitanBrowserTraceBuffer records;

const char *titan_browser_trace_identity(void) {
    return "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
}

int trace_capture_once(void) {
    return titan_browser_trace_capture(&records, TITAN_BROWSER_TRACE_CAPACITY);
}
