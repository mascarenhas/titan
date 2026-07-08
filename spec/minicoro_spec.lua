local lfs = require "lfs"

local function write_file(path, contents)
    local f = assert(io.open(path, "wb"))
    f:write(contents)
    f:close()
end

local function run_command(command)
    local f = assert(io.popen(command .. " 2>&1"))
    local out = f:read("*a")
    local ok = f:close()
    return ok, out
end

local function command_available(command)
    local ok = os.execute("command -v " .. command .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function with_valgrind_stub(fn)
    local root = os.tmpname() .. "-vg"
    local vgdir = root .. "/valgrind"
    assert(lfs.mkdir(root))
    assert(lfs.mkdir(vgdir))
    write_file(vgdir .. "/valgrind.h", [[
#ifndef TEST_VALGRIND_H
#define TEST_VALGRIND_H
#define VALGRIND_STACK_REGISTER(start, end) (1U)
#define VALGRIND_STACK_DEREGISTER(id) ((void)(id))
#endif
]])
    local ok, res = pcall(fn, root)
    os.remove(vgdir .. "/valgrind.h")
    lfs.rmdir(vgdir)
    lfs.rmdir(root)
    if not ok then
        error(res, 0)
    end
    return res
end

local function run_c_probe(source, cflags, runner)
    local stem = os.tmpname()
    local cfile = stem .. ".c"
    local exe = stem
    write_file(cfile, source)
    local compile = string.format(
        "cc --std=c99 -Wall -Wextra -I. %s -o %s %s",
        cflags or "", exe, cfile)
    local ok, compile_out = run_command(compile)
    os.remove(cfile)
    assert.truthy(ok, compile_out)
    local run_ok, out = run_command((runner or "") .. exe)
    os.remove(exe)
    assert.truthy(run_ok, out)
    return out
end

local function minicoro_suite(defines)
    local prefix = table.concat(defines or {}, "\n")
    if prefix ~= "" then
        prefix = prefix .. "\n"
    end
    return prefix .. [[
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define MINICORO_IMPL
#include "titan-runtime/minicoro.h"

#define TEST_STACK_SIZE (1024 * 1024)

static const char main_tag[] = "main";
static const char a_tag[] = "a";
static const char b_tag[] = "b";
static const char d_tag[] = "d";
static const char missing_tag[] = "missing";

static int tagcmp(void *t1, void *t2) {
  return strcmp((const char *)t1, (const char *)t2) == 0;
}

static mco_desc test_desc(void (*entry)(mco_coro *co)) {
  return mco_desc_init(entry, TEST_STACK_SIZE);
}

static mco_coro *immediate_a;
static mco_coro *immediate_b;
static int immediate_step;

static void immediate_b_entry(mco_coro *co) {
  assert(immediate_step == 1);
  assert(mco_status(immediate_a) == MCO_NORMAL);
  assert(mco_is_yieldable(co, (void *)a_tag));
  assert(mco_is_yieldable(co, (void *)main_tag));
  assert(!mco_is_yieldable(co, (void *)missing_tag));
  immediate_step = 2;
  assert(mco_yield(co, (void *)a_tag) == MCO_SUCCESS);
  assert(immediate_step == 3);
  immediate_step = 4;
}

static void immediate_a_entry(mco_coro *co) {
  (void)co;
  assert(immediate_step == 0);
  immediate_step = 1;
  assert(mco_resume(immediate_b, (void *)a_tag) == MCO_SUCCESS);
  assert(immediate_step == 2);
  assert(mco_status(immediate_a) == MCO_RUNNING);
  assert(mco_status(immediate_b) == MCO_SUSPENDED);
  assert(immediate_a->stacked_co == NULL);
  immediate_step = 3;
  assert(mco_resume(immediate_b, (void *)a_tag) == MCO_SUCCESS);
  assert(immediate_step == 4);
  assert(mco_status(immediate_b) == MCO_DEAD);
  immediate_step = 5;
}

static void test_immediate_tagged_yield(void) {
  mco_desc da = test_desc(immediate_a_entry);
  mco_desc db = test_desc(immediate_b_entry);
  immediate_step = 0;
  assert(mco_create(&immediate_a, &da) == MCO_SUCCESS);
  assert(mco_create(&immediate_b, &db) == MCO_SUCCESS);
  assert(mco_resume(immediate_a, (void *)main_tag) == MCO_SUCCESS);
  assert(immediate_step == 5);
  assert(mco_status(immediate_a) == MCO_DEAD);
  assert(mco_status(immediate_b) == MCO_DEAD);
  assert(mco_destroy(immediate_a) == MCO_SUCCESS);
  assert(mco_destroy(immediate_b) == MCO_SUCCESS);
}

static mco_coro *chain_a;
static mco_coro *chain_b;
static mco_coro *chain_c;
static int chain_step;

static void chain_c_entry(mco_coro *co) {
  assert(chain_step == 2);
  assert(mco_is_yieldable(co, (void *)main_tag));
  assert(mco_is_yieldable(co, (void *)a_tag));
  assert(mco_is_yieldable(co, (void *)b_tag));
  chain_step = 3;
  assert(mco_yield(co, (void *)main_tag) == MCO_SUCCESS);
  assert(chain_step == 4);
  chain_step = 5;
}

static void chain_b_entry(mco_coro *co) {
  (void)co;
  assert(chain_step == 1);
  chain_step = 2;
  assert(mco_resume(chain_c, (void *)b_tag) == MCO_SUCCESS);
  assert(chain_step == 5);
  chain_step = 6;
}

static void chain_a_entry(mco_coro *co) {
  (void)co;
  assert(chain_step == 0);
  chain_step = 1;
  assert(mco_resume(chain_b, (void *)a_tag) == MCO_SUCCESS);
  assert(chain_step == 6);
  chain_step = 7;
}

static void test_long_tagged_chain(void) {
  mco_desc da = test_desc(chain_a_entry);
  mco_desc db = test_desc(chain_b_entry);
  mco_desc dc = test_desc(chain_c_entry);
  chain_step = 0;
  assert(mco_create(&chain_a, &da) == MCO_SUCCESS);
  assert(mco_create(&chain_b, &db) == MCO_SUCCESS);
  assert(mco_create(&chain_c, &dc) == MCO_SUCCESS);

  assert(mco_resume(chain_a, (void *)main_tag) == MCO_SUCCESS);
  assert(chain_step == 3);
  assert(mco_status(chain_a) == MCO_SUSPENDED);
  assert(mco_status(chain_b) == MCO_STACKED);
  assert(mco_status(chain_c) == MCO_STACKED);
  assert(chain_a->stacked_co == chain_c);
  assert(mco_resume(chain_b, (void *)a_tag) == MCO_NOT_SUSPENDED);
  assert(mco_resume(chain_c, (void *)b_tag) == MCO_NOT_SUSPENDED);

  chain_step = 4;
  assert(mco_resume(chain_a, (void *)main_tag) == MCO_SUCCESS);
  assert(chain_step == 7);
  assert(mco_status(chain_a) == MCO_DEAD);
  assert(mco_status(chain_b) == MCO_DEAD);
  assert(mco_status(chain_c) == MCO_DEAD);
  assert(mco_destroy(chain_a) == MCO_SUCCESS);
  assert(mco_destroy(chain_b) == MCO_SUCCESS);
  assert(mco_destroy(chain_c) == MCO_SUCCESS);
}

static void test_destroy_suspended_handler_abandons_stacked_chain(void) {
  mco_desc da = test_desc(chain_a_entry);
  mco_desc db = test_desc(chain_b_entry);
  mco_desc dc = test_desc(chain_c_entry);
  chain_step = 0;
  assert(mco_create(&chain_a, &da) == MCO_SUCCESS);
  assert(mco_create(&chain_b, &db) == MCO_SUCCESS);
  assert(mco_create(&chain_c, &dc) == MCO_SUCCESS);

  assert(mco_resume(chain_a, (void *)main_tag) == MCO_SUCCESS);
  assert(chain_step == 3);
  assert(mco_status(chain_a) == MCO_SUSPENDED);
  assert(mco_status(chain_b) == MCO_STACKED);
  assert(mco_status(chain_c) == MCO_STACKED);

  assert(mco_destroy(chain_a) == MCO_SUCCESS);
  assert(mco_status(chain_b) == MCO_DEAD);
  assert(mco_status(chain_c) == MCO_DEAD);
  assert(chain_b->prev_co == NULL);
  assert(chain_c->prev_co == NULL);
  assert(mco_destroy(chain_b) == MCO_SUCCESS);
  assert(mco_destroy(chain_c) == MCO_SUCCESS);
}

static mco_coro *handoff_driver;
static mco_coro *handoff_a;
static mco_coro *handoff_b;
static int handoff_step;

static void handoff_b_entry(mco_coro *co) {
  assert(handoff_step == 2);
  handoff_step = 3;
  assert(mco_yield(co, (void *)main_tag) == MCO_SUCCESS);
  assert(handoff_step == 5);
  handoff_step = 6;
}

static void handoff_a_entry(mco_coro *co) {
  (void)co;
  assert(handoff_step == 1);
  handoff_step = 2;
  assert(mco_resume(handoff_b, (void *)a_tag) == MCO_SUCCESS);
  assert(handoff_step == 6);
  handoff_step = 7;
}

static void handoff_driver_entry(mco_coro *co) {
  assert(handoff_step == 0);
  handoff_step = 1;
  assert(mco_resume(handoff_a, (void *)main_tag) == MCO_SUCCESS);
  assert(handoff_step == 3);
  handoff_step = 4;
  assert(mco_yield(co, (void *)d_tag) == MCO_SUCCESS);
  assert(handoff_step == 8);
  handoff_step = 9;
}

static void test_stacked_handler_can_be_resumed_by_a_different_resumer(void) {
  mco_desc dd = test_desc(handoff_driver_entry);
  mco_desc da = test_desc(handoff_a_entry);
  mco_desc db = test_desc(handoff_b_entry);
  handoff_step = 0;
  assert(mco_create(&handoff_driver, &dd) == MCO_SUCCESS);
  assert(mco_create(&handoff_a, &da) == MCO_SUCCESS);
  assert(mco_create(&handoff_b, &db) == MCO_SUCCESS);

  assert(mco_resume(handoff_driver, (void *)d_tag) == MCO_SUCCESS);
  assert(handoff_step == 4);
  assert(mco_status(handoff_driver) == MCO_SUSPENDED);
  assert(mco_status(handoff_a) == MCO_SUSPENDED);
  assert(mco_status(handoff_b) == MCO_STACKED);

  handoff_step = 5;
  assert(mco_resume(handoff_a, (void *)main_tag) == MCO_SUCCESS);
  assert(handoff_step == 7);
  assert(mco_status(handoff_a) == MCO_DEAD);
  assert(mco_status(handoff_b) == MCO_DEAD);
  assert(mco_status(handoff_driver) == MCO_SUSPENDED);

  handoff_step = 8;
  assert(mco_resume(handoff_driver, (void *)d_tag) == MCO_SUCCESS);
  assert(handoff_step == 9);
  assert(mco_status(handoff_driver) == MCO_DEAD);

  assert(mco_destroy(handoff_driver) == MCO_SUCCESS);
  assert(mco_destroy(handoff_a) == MCO_SUCCESS);
  assert(mco_destroy(handoff_b) == MCO_SUCCESS);
}

static mco_coro *storage_co;
static int storage_step;

static void storage_entry(mco_coro *co) {
  int value = 0;
  assert(storage_step == 0);
  assert(mco_pop(co, &value, sizeof(value)) == MCO_SUCCESS);
  assert(value == 42);
  value = 7;
  assert(mco_push(co, &value, sizeof(value)) == MCO_SUCCESS);
  storage_step = 1;
  assert(mco_yield(co, (void *)main_tag) == MCO_SUCCESS);
  assert(storage_step == 2);
  assert(mco_pop(co, &value, sizeof(value)) == MCO_SUCCESS);
  assert(value == 8);
  value = 9;
  assert(mco_push(co, &value, sizeof(value)) == MCO_SUCCESS);
  storage_step = 3;
}

static void test_storage_across_tagged_transfers(void) {
  mco_desc desc = test_desc(storage_entry);
  int value = 42;
  storage_step = 0;
  assert(mco_create(&storage_co, &desc) == MCO_SUCCESS);
  assert(mco_push(storage_co, &value, sizeof(value)) == MCO_SUCCESS);
  assert(mco_resume(storage_co, (void *)main_tag) == MCO_SUCCESS);
  assert(storage_step == 1);
  assert(mco_pop(storage_co, &value, sizeof(value)) == MCO_SUCCESS);
  assert(value == 7);
  value = 8;
  assert(mco_push(storage_co, &value, sizeof(value)) == MCO_SUCCESS);
  storage_step = 2;
  assert(mco_resume(storage_co, (void *)main_tag) == MCO_SUCCESS);
  assert(storage_step == 3);
  assert(mco_pop(storage_co, &value, sizeof(value)) == MCO_SUCCESS);
  assert(value == 9);
  assert(mco_status(storage_co) == MCO_DEAD);
  assert(mco_destroy(storage_co) == MCO_SUCCESS);
}

static mco_coro *error_co;
static int error_step;

static void error_entry(mco_coro *co) {
  assert(error_step == 0);
  assert(mco_yield(co, (void *)missing_tag) == MCO_INVALID_OPERATION);
  error_step = 1;
}

static void test_error_cases(void) {
  mco_desc desc = test_desc(error_entry);
  error_step = 0;
  assert(!mco_is_yieldable(NULL, (void *)main_tag));
  assert(mco_resume(NULL, (void *)main_tag) == MCO_INVALID_COROUTINE);
  assert(mco_yield(NULL, (void *)main_tag) == MCO_INVALID_COROUTINE);
  assert(mco_create(&error_co, &desc) == MCO_SUCCESS);
  assert(mco_resume(error_co, (void *)main_tag) == MCO_SUCCESS);
  assert(error_step == 1);
  assert(mco_status(error_co) == MCO_DEAD);
  assert(mco_resume(error_co, (void *)main_tag) == MCO_NOT_SUSPENDED);
  assert(mco_destroy(error_co) == MCO_SUCCESS);
}

int main(void) {
  mco_set_tag_comparator(tagcmp);
  test_immediate_tagged_yield();
  test_long_tagged_chain();
  test_destroy_suspended_handler_abandons_stacked_chain();
  test_stacked_handler_can_be_resumed_by_a_different_resumer();
  test_storage_across_tagged_transfers();
  test_error_cases();
  puts("ok");
  return 0;
}
]]
end

local function run_suite_variant(variant)
    local function run(include_dir)
        local cflags = variant.cflags or ""
        if include_dir then
            cflags = cflags .. " -I" .. include_dir
        end
        return run_c_probe(minicoro_suite(variant.defines), cflags, variant.runner)
    end

    if variant.valgrind_stub then
        return with_valgrind_stub(run)
    end
    return run()
end

describe("minicoro tagged extension", function()
    local variants = {
        {
            name = "default backend",
            defines = {},
        },
        {
            name = "ASM backend",
            defines = { "#define MCO_USE_ASM" },
        },
        {
            name = "UCONTEXT backend",
            defines = { "#define MCO_USE_UCONTEXT" },
            cflags = "-D_XOPEN_SOURCE=700",
        },
        {
            name = "ASM backend with VMEM allocator",
            defines = {
                "#define MCO_USE_ASM",
                "#define MCO_USE_VMEM_ALLOCATOR",
            },
        },
        {
            name = "ASM backend with Titan runtime flags",
            defines = {
                "#define MCO_NO_DEBUG",
                "#define MCO_USE_ASM",
                "#define MCO_USE_VMEM_ALLOCATOR",
            },
        },
        {
            name = "UCONTEXT backend with VMEM allocator",
            defines = {
                "#define MCO_USE_UCONTEXT",
                "#define MCO_USE_VMEM_ALLOCATOR",
            },
            cflags = "-D_XOPEN_SOURCE=700",
        },
        {
            name = "UCONTEXT backend with Titan runtime flags",
            defines = {
                "#define MCO_NO_DEBUG",
                "#define MCO_USE_UCONTEXT",
                "#define MCO_USE_VMEM_ALLOCATOR",
            },
            cflags = "-D_XOPEN_SOURCE=700",
        },
        {
            name = "ASM backend with Valgrind hooks",
            defines = {
                "#define MCO_USE_ASM",
                "#define MCO_USE_VALGRIND",
            },
            valgrind_stub = true,
        },
        {
            name = "UCONTEXT backend with Valgrind hooks",
            defines = {
                "#define MCO_USE_UCONTEXT",
                "#define MCO_USE_VALGRIND",
            },
            cflags = "-D_XOPEN_SOURCE=700",
            valgrind_stub = true,
        },
        {
            name = "UCONTEXT backend with VMEM and Valgrind hooks",
            defines = {
                "#define MCO_USE_UCONTEXT",
                "#define MCO_USE_VMEM_ALLOCATOR",
                "#define MCO_USE_VALGRIND",
            },
            cflags = "-D_XOPEN_SOURCE=700",
            valgrind_stub = true,
        },
    }

    for _, variant in ipairs(variants) do
        it("passes tagged coroutine behavior on " .. variant.name, function()
            local out = run_suite_variant(variant)
            assert.match("ok", out)
        end)
    end

    it("runs tagged coroutine behavior under real Valgrind when available", function()
        if not command_available("valgrind") then
            return
        end
        local out = run_suite_variant({
            defines = {
                "#define MCO_USE_UCONTEXT",
                "#define MCO_USE_VALGRIND",
            },
            cflags = "-D_XOPEN_SOURCE=700",
            runner = "valgrind --quiet --error-exitcode=99 ",
        })
        assert.match("ok", out)
    end)
end)
