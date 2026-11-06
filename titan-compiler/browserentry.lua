local util = require "titan-compiler.util"
local M = {}

-- Every image has one persistent protected owner state. Protocol-only images
-- use an empty initializer; a Titan image supplies its module bootstrap.
local template = [[
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "titan.h"
#include "titan/browser.h"

struct titan_browser_arguments {
    int argc;
    const unsigned char *const *argv;
    const size_t *lengths;
};
$DECLARATIONS
$INITIALIZER
$WORKER

int titan_browser_initialize(uint64_t operation_id) {
    return titan_browser_initialize_image(operation_id, titan_browser_initialize_worker,
        "$PROGNAME", $STATE_STATUS);
}
int titan_browser_entry(uint64_t operation_id, int argc,
        const unsigned char *const *argv, const size_t *lengths) {
    struct titan_browser_arguments arguments = {argc, argv, lengths};
    return titan_browser_main_image(operation_id, titan_browser_worker, &arguments);
}
int titan_browser_close(uint64_t operation_id) {
    return titan_browser_close_image(operation_id);
}
]]

function M.contents(worker, options)
    options = options or {}
    return util.render(template, { DECLARATIONS = options.declarations or "",
        INITIALIZER = options.initializer or
            "static int titan_browser_initialize_worker(lua_State *L) { (void)L; return 0; }",
        WORKER = worker, PROGNAME = options.program_name or "titan",
        STATE_STATUS = tostring(options.state_status or 1) })
end

return M
