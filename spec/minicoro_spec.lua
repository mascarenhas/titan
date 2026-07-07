local function write_file(path, contents)
    local f = assert(io.open(path, "wb"))
    f:write(contents)
    f:close()
end

local function run_c_probe(source)
    local stem = os.tmpname()
    local cfile = stem .. ".c"
    local exe = stem
    write_file(cfile, source)
    local compile = string.format(
        "cc --std=c99 -Wall -Wextra -I. -o %s %s 2>&1",
        exe, cfile)
    local ok = os.execute(compile)
    assert.truthy(ok)
    local f = assert(io.popen(exe .. " 2>&1"))
    local out = f:read("*a")
    local rok = f:close()
    os.remove(cfile)
    os.remove(exe)
    assert.truthy(rok, out)
    return out
end

describe("minicoro tagged extension", function()
    it("stacks skipped coroutines and restores them through the matching handler", function()
        local out = run_c_probe([[
            #include <assert.h>
            #include <stdio.h>
            #include <string.h>
            #define MINICORO_IMPL
            #include "titan-runtime/minicoro.h"

            static mco_coro *a;
            static mco_coro *b;
            static const char main_tag[] = "main";
            static const char a_tag[] = "a";
            static const char missing_tag[] = "missing";
            static int step = 0;

            static int tagcmp(void *t1, void *t2) {
              return strcmp((const char *)t1, (const char *)t2) == 0;
            }

            static void b_entry(mco_coro *co) {
              assert(step == 1);
              assert(mco_is_yieldable_tagged(co, (void *)main_tag, tagcmp));
              assert(!mco_is_yieldable_tagged(co, (void *)missing_tag, tagcmp));
              step = 2;
              assert(mco_yield_tagged(co, (void *)main_tag, tagcmp) == MCO_SUCCESS);
              assert(step == 3);
              step = 4;
            }

            static void a_entry(mco_coro *co) {
              (void)co;
              assert(step == 0);
              step = 1;
              assert(mco_resume_tagged(b, (void *)a_tag, tagcmp) == MCO_SUCCESS);
              assert(step == 4);
              step = 5;
            }

            int main(void) {
              mco_desc da = mco_desc_init(a_entry, 0);
              mco_desc db = mco_desc_init(b_entry, 0);
              assert(mco_create(&a, &da) == MCO_SUCCESS);
              assert(mco_create(&b, &db) == MCO_SUCCESS);

              assert(mco_resume_tagged(a, (void *)main_tag, tagcmp) == MCO_SUCCESS);
              assert(step == 2);
              assert(mco_status(a) == MCO_STACKED);
              assert(mco_status(b) == MCO_SUSPENDED);
              assert(mco_resume(a) == MCO_NOT_SUSPENDED);

              step = 3;
              assert(mco_resume_tagged(a, (void *)main_tag, tagcmp) == MCO_SUCCESS);
              assert(step == 5);
              assert(mco_status(a) == MCO_DEAD);
              assert(mco_status(b) == MCO_DEAD);

              assert(mco_destroy(a) == MCO_SUCCESS);
              assert(mco_destroy(b) == MCO_SUCCESS);
              puts("ok");
              return 0;
            }
        ]])

        assert.match("ok", out)
    end)
end)
