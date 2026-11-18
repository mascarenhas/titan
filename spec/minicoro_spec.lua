local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local browser_support = require "spec.fixtures.browser_runtime.support"
local browser_toolchain = require "spec.support.browser_toolchain"

local function write_file(path, contents)
    local f = assert(io.open(path, "wb"))
    f:write(contents)
    f:close()
end

local function run_command(argv)
    local result = compiler_io.new_sync():run(argv)
    return result.ok, result.output or result.diagnostic or ""
end

local function command_available(command)
    return run_command({ command, "--version" })
end

local function with_valgrind_stub(fn)
    local reservation = temporary.name()
    os.remove(reservation)
    local root = reservation .. "-vg"
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
    local stem = temporary.name()
    os.remove(stem)
    local cfile = stem .. ".c"
    local exe = stem .. (platform.windows and ".exe" or "")
    write_file(cfile, source)
    local cc = os.getenv("MINICORO_TEST_CC") or
        (platform.windows and (os.getenv("CC") or "clang.exe") or "cc")
    local compile = assert(cdriver.split_shell_words(cc))
    for _, word in ipairs({ "--std=c99", "-Wall", "-Wextra", "-I." }) do
        compile[#compile + 1] = word
    end
    for _, word in ipairs(assert(cdriver.split_shell_words(cflags or ""))) do
        compile[#compile + 1] = word
    end
    compile[#compile + 1] = "-o"
    compile[#compile + 1] = exe
    compile[#compile + 1] = cfile
    local ok, compile_out = run_command(compile)
    os.remove(cfile)
    assert.truthy(ok, compile_out)
    local argv = assert(cdriver.split_shell_words(runner or ""))
    argv[#argv + 1] = exe
    local run_ok, out = run_command(argv)
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

static int corrupt_magic_seen;

static void corrupt_magic_entry(mco_coro *co) {
  size_t saved = co->magic_number;
  co->magic_number = 0;
  assert(mco_yield(co, (void *)main_tag) == MCO_STACK_OVERFLOW);
  co->magic_number = saved;
  corrupt_magic_seen = 1;
}

static void test_magic_sentinel_under_sanitizers(void) {
  mco_coro *co;
  mco_desc desc = test_desc(corrupt_magic_entry);
  corrupt_magic_seen = 0;
  assert(mco_create(&co, &desc) == MCO_SUCCESS);
  assert(mco_resume(co, (void *)main_tag) == MCO_SUCCESS);
  assert(corrupt_magic_seen == 1);
  assert(mco_status(co) == MCO_DEAD);
  assert(mco_destroy(co) == MCO_SUCCESS);
}

int main(void) {
#ifdef TEST_FIXED_TAG_COMPARATOR
  mco_set_tag_comparator(NULL);
#else
  mco_set_tag_comparator(tagcmp);
#endif
  test_immediate_tagged_yield();
  test_long_tagged_chain();
  test_destroy_suspended_handler_abandons_stacked_chain();
  test_stacked_handler_can_be_resumed_by_a_different_resumer();
  test_storage_across_tagged_transfers();
  test_error_cases();
  test_magic_sentinel_under_sanitizers();
  puts("ok");
  return 0;
}
]]
end

local function run_suite_variant(variant)
    local function run(include_dir)
        local cflags = table.concat({
            variant.cflags or "",
            os.getenv("MINICORO_TEST_CFLAGS") or "",
        }, " ")
        if include_dir then
            cflags = cflags .. " -I" .. assert(cdriver.shell_quote(include_dir))
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
            name = "default backend with fixed tag comparator",
            defines = {
                "static int tagcmp(void *, void *);",
                "#define MCO_TAG_COMPARATOR tagcmp",
                "#define TEST_FIXED_TAG_COMPARATOR",
            },
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
            if platform.windows and variant.name:find("UCONTEXT", 1, true) then
                pending("The UCONTEXT backend requires the POSIX ucontext API")
                return
            end
            local out = run_suite_variant(variant)
            assert.match("ok", out)
        end)
    end

    it("omits sanitizer bookkeeping from standard public layouts", function()
        local out = run_c_probe([[
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include "titan-runtime/minicoro.h"

#ifdef _MCO_USE_ASAN
#error unexpected ASan layout in standard build
#endif
#ifdef _MCO_USE_TSAN
#error unexpected TSan layout in standard build
#endif

int main(void) {
  mco_runtime runtime = {0};
  mco_desc desc = {0};
  desc.runtime = &runtime;
  assert(desc.runtime->current_co == NULL);
  assert(sizeof(mco_runtime) == sizeof(mco_coro *));
  assert(offsetof(mco_coro, magic_number) ==
         offsetof(mco_coro, storage_size) + sizeof(size_t));
  puts("ok");
  return 0;
}
        ]])
        assert.match("ok", out)
    end)

    it("includes only ASan bookkeeping in ASan public layouts", function()
        local out = run_c_probe([[
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#define __SANITIZE_ADDRESS__ 1
#include "titan-runtime/minicoro.h"

#ifndef _MCO_USE_ASAN
#error missing ASan layout in ASan build
#endif
#ifdef _MCO_USE_TSAN
#error unexpected TSan layout in ASan-only build
#endif

int main(void) {
  mco_runtime runtime = {0};
  mco_coro co = {0};
  runtime.asan_main_fake_stack = NULL;
  runtime.asan_main_stack_bottom = NULL;
  runtime.asan_main_stack_size = 0;
  co.asan_prev_stack = NULL;
  assert(offsetof(mco_coro, magic_number) ==
         offsetof(mco_coro, asan_prev_stack) + sizeof(void *));
  puts("ok");
  return 0;
}
        ]])
        assert.match("ok", out)
    end)

    it("refreshes ASan main-stack bounds when a runtime moves between caller stacks", function()
        local out = run_c_probe([[
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#define __SANITIZE_ADDRESS__ 1
#define MINICORO_IMPL
#include "titan-runtime/minicoro.h"

static mco_runtime shared_runtime;
static int main_tag_value = 1;
static int nested_tag_value = 2;
static void *main_tag = &main_tag_value;
static void *nested_tag = &nested_tag_value;
static const void *next_caller_bottom;
static size_t next_caller_size;
static const void *last_switch_bottom;
static size_t last_switch_size;
static mco_coro *inner_co;

void __sanitizer_start_switch_fiber(void **fake_stack_save,
                                    const void *bottom,
                                    size_t size) {
  if (fake_stack_save) *fake_stack_save = (void *)0x1111;
  last_switch_bottom = bottom;
  last_switch_size = size;
}

void __sanitizer_finish_switch_fiber(void *fake_stack_save,
                                     const void **bottom_old,
                                     size_t *size_old) {
  (void)fake_stack_save;
  if (bottom_old) *bottom_old = next_caller_bottom;
  if (size_old) *size_old = next_caller_size;
}

static int tagcmp(void *a, void *b) {
  return a == b;
}

static void inner_entry(mco_coro *co) {
  assert(mco_yield(co, nested_tag) == MCO_SUCCESS);
}

static void outer_entry(mco_coro *co) {
  mco_desc desc = mco_desc_init(inner_entry, 65536);
  desc.runtime = &shared_runtime;
  assert(mco_create(&inner_co, &desc) == MCO_SUCCESS);
  next_caller_bottom = co->stack_base;
  next_caller_size = co->stack_size;
  assert(mco_resume(inner_co, nested_tag) == MCO_SUCCESS);
  assert(mco_yield(co, main_tag) == MCO_SUCCESS);
  next_caller_bottom = co->stack_base;
  next_caller_size = co->stack_size;
  assert(mco_resume(inner_co, nested_tag) == MCO_SUCCESS);
  assert(mco_destroy(inner_co) == MCO_SUCCESS);
}

int main(void) {
  mco_coro *co = NULL;
  mco_desc desc = mco_desc_init(outer_entry, 65536);
  mco_set_tag_comparator(tagcmp);
  desc.runtime = &shared_runtime;
  assert(mco_create(&co, &desc) == MCO_SUCCESS);

  next_caller_bottom = (const void *)0x100000;
  next_caller_size = 0x20000;
  assert(mco_resume(co, main_tag) == MCO_SUCCESS);
  assert(shared_runtime.asan_main_stack_bottom == (const void *)0x100000);
  assert(shared_runtime.asan_main_stack_size == 0x20000);
  assert(last_switch_bottom == (const void *)0x100000);
  assert(last_switch_size == 0x20000);

  next_caller_bottom = (const void *)0x400000;
  next_caller_size = 0x80000;
  assert(mco_resume(co, main_tag) == MCO_SUCCESS);
  assert(shared_runtime.asan_main_stack_bottom == (const void *)0x400000);
  assert(shared_runtime.asan_main_stack_size == 0x80000);
  assert(last_switch_bottom == (const void *)0x400000);
  assert(last_switch_size == 0x80000);
  assert(mco_destroy(co) == MCO_SUCCESS);
  puts("ok");
  return 0;
}
        ]])
        assert.match("ok", out)
    end)

    it("includes only TSan bookkeeping in TSan public layouts", function()
        local out = run_c_probe([[
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#define __SANITIZE_THREAD__ 1
#include "titan-runtime/minicoro.h"

#ifdef _MCO_USE_ASAN
#error unexpected ASan layout in TSan-only build
#endif
#ifndef _MCO_USE_TSAN
#error missing TSan layout in TSan build
#endif

int main(void) {
  mco_runtime runtime = {0};
  mco_coro co = {0};
  co.tsan_prev_fiber = NULL;
  co.tsan_fiber = NULL;
  assert(sizeof(runtime) == sizeof(mco_coro *));
  assert(offsetof(mco_coro, magic_number) ==
         offsetof(mco_coro, tsan_fiber) + sizeof(void *));
  puts("ok");
  return 0;
}
        ]])
        assert.match("ok", out)
    end)

    it("runs tagged coroutine behavior under real Valgrind when available", function()
        if platform.windows then
            pending("Valgrind requires a supported Unix host")
            return
        end
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

    -- The unwind floor that titan_coroutine_enter (titan-runtime/minicoro.c)
    -- installs below every Titan coroutine entry. No Titan-level program can
    -- make an error escape coro_entry's catch, so a C entry drives it here.
    it("delivers escaped errors and lands unwinds on the Titan coroutine floor", function()
        local driver = require "titan-compiler.driver"
        local prefix = require("spec.support.installed_prefix").active()
        local stem = temporary.name()
        os.remove(stem)
        local harness = stem .. ".c"
        local executable = stem .. (platform.windows and ".exe" or "")
        write_file(harness, browser_support.files.read(
            browser_support.fixture .. "/minicoro_floor.c"))
        local compiler = assert(cdriver.split_shell_words(driver.CC))
        local arguments = {
            "--std=c99", "-O0", "-g", "-Wall", "-Wextra",
            "-Ititan-runtime", "-I" .. prefix .. "/src/lua-5.5.1",
            harness, "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            prefix .. "/lib/liblua.a", "-o", executable,
            "-lm", "-pthread",
        }
        if platform.windows then
            arguments = {
                "--std=c99", "-O0", "-g", "-Wall", "-Wextra",
                "-I" .. prefix .. "/include", "-I" .. prefix .. "/src/lua-5.5.1",
                harness, prefix .. "/lib/titan/0.6/libtitan.a",
                prefix .. "/lib/libbacktrace.a", prefix .. "/lib/liblua55.a",
                "-static-libgcc", "-lbcrypt", "-o", executable,
            }
        end
        for _, argument in ipairs(arguments) do
            compiler[#compiler + 1] = argument
        end
        -- The harness links the instrumented runtime archive, so it needs the
        -- same extra compile and link flags (for example sanitizer runtimes).
        for _, flags in ipairs({ driver.EXTRA_CPPFLAGS or {}, driver.EXTRA_CFLAGS or {},
                                 driver.EXTRA_LDFLAGS or {} }) do
            for _, flag in ipairs(flags) do
                compiler[#compiler + 1] = flag
            end
        end
        if not platform.windows and not driver.IS_DARWIN then
            compiler[#compiler + 1] = "-ldl"
        end
        local linked, link_out = run_command(compiler)
        os.remove(harness)
        assert.truthy(linked, link_out)
        local ran, out = run_command({ executable })
        os.remove(executable)
        assert.truthy(ran, out)
        assert.match("ok", out)
    end)
end)

describe("minicoro Emscripten JSPI backend", function()
    local workspace
    after_each(function()
        if workspace then browser_support.files.remove(workspace); workspace = nil end
    end)

    for debug_off = 0, 1 do
        for vmem = 0, 1 do
            for comparator = 0, 1 do
                local name = string.format("debug%d-vmem%d-comparator%d", debug_off, vmem, comparator)
                it("runs all seven tagged scenarios on " .. name .. " in both engines", function()
                    local info, why = browser_toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
                    workspace = browser_support.workspace()
                    local defines = {}
                    if debug_off == 1 then defines[#defines + 1] = "#define MCO_NO_DEBUG" end
                    if vmem == 1 then defines[#defines + 1] = "#define MCO_USE_VMEM_ALLOCATOR" end
                    if comparator == 1 then
                        defines[#defines + 1] = "static int tagcmp(void *, void *);"
                        defines[#defines + 1] = "#define MCO_TAG_COMPARATOR tagcmp"
                        defines[#defines + 1] = "#define TEST_FIXED_TAG_COMPARATOR"
                    end
                    local ok, log = browser_support.c_image(info, workspace, name,
                        minicoro_suite(defines), { purpose = "minicoro", assertions = 2 })
                    assert.truthy(ok, log)
                    browser_toolchain.check_imports(workspace .. "/" .. name .. ".mjs", { "entry" })
                    for _, engine in ipairs({ "node", "chromium" }) do
                        ok, log = browser_support.image(info, workspace, engine, name)
                        assert.truthy(ok, log)
                        assert.truthy(log:find("ok", 1, true), log)
                    end
                end)
            end
        end
    end

    it("runs all three production unwind-floor scenarios in both engines", function()
        local info, why = browser_toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = browser_support.workspace()
        local ok, log = browser_support.c_image(info, workspace, "unwind-floor",
            browser_support.files.read(browser_support.fixture .. "/minicoro_floor.c"),
            { purpose = "minicoro", assertions = 2 })
        assert.truthy(ok, log)
        browser_toolchain.check_imports(workspace .. "/unwind-floor.mjs", { "entry" })
        for _, engine in ipairs({ "node", "chromium" }) do
            ok, log = browser_support.image(info, workspace, engine, "unwind-floor")
            assert.truthy(ok, log)
            assert.truthy(log:find("ok", 1, true), log)
        end
    end)

    it("retires unstarted, suspended and stacked engine continuations before native reuse", function()
        local info, why = browser_toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = browser_support.workspace()
        local control = [[
#include <assert.h>
#include <stdio.h>
#define MINICORO_IMPL
#include "titan-runtime/minicoro.h"
static int ran, continued;
static mco_coro *inner;
static void *tag = (void *)1;
static int same(void *a, void *b) { return a == b; }
static void parked(mco_coro *co) {
  ++ran;
  assert(mco_yield(co, tag) == MCO_SUCCESS);
  ++continued;
}
static void outer(mco_coro *co) {
  (void)co;
  assert(mco_resume(inner, (void *)2) == MCO_SUCCESS);
  ++continued;
}
static mco_coro *make(void (*entry)(mco_coro *)) {
  mco_coro *co = NULL;
  mco_desc desc = mco_desc_init(entry, 262144);
  assert(mco_create(&co, &desc) == MCO_SUCCESS);
  return co;
}
int main(void) {
  mco_set_tag_comparator(same);
  mco_coro failed;
  mco_desc invalid = mco_desc_init(NULL, 262144);
  assert(mco_init(&failed, &invalid) == MCO_INVALID_ARGUMENTS);
  assert(mco_uninit(&failed) == MCO_SUCCESS);
  mco_coro *idle = make(parked);
  assert(mco_uninit(idle) == MCO_SUCCESS);
  assert(mco_uninit(idle) == MCO_SUCCESS);
  assert(mco_destroy(idle) == MCO_SUCCESS && ran == 0);
  mco_coro *single = make(parked);
  assert(mco_resume(single, tag) == MCO_SUCCESS && ran == 1);
  assert(mco_uninit(single) == MCO_SUCCESS);
  assert(mco_destroy(single) == MCO_SUCCESS && continued == 0);
  inner = make(parked);
  mco_coro *handler = make(outer);
  assert(mco_resume(handler, tag) == MCO_SUCCESS);
  assert(mco_status(inner) == MCO_STACKED && ran == 2);
  assert(mco_uninit(handler) == MCO_SUCCESS);
  assert(mco_destroy(handler) == MCO_SUCCESS);
  assert(mco_destroy(inner) == MCO_SUCCESS && continued == 0);
  puts("minicoro JSPI retirement: unstarted=1 suspended=1 stacked=2 continued=0 repeated_uninit=3 failed_init=1");
  return 0;
}
]]
        local ok, log = browser_support.c_image(info, workspace, "retirement",
            control, { purpose = "minicoro", assertions = 2 })
        assert.truthy(ok, log)
        browser_toolchain.check_imports(workspace .. "/retirement.mjs", { "entry" })
        for _, engine in ipairs({ "node", "chromium" }) do
            ok, log = browser_support.image(info, workspace, engine, "retirement")
            assert.truthy(ok, log)
            assert.truthy(log:find("unstarted=1 suspended=1 stacked=2 continued=0", 1, true), log)
        end
    end)
end)
