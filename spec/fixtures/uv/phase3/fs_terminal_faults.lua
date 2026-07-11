-- Runs only against the generated __test_fs_* uv variant.
local root = assert(arg[1], "missing Phase 3 temp directory")
local scenario = assert(arg[2], "missing terminal fault scenario")
local fs = require "titan.fs"
local timer = require "titan.timer"
local uv = require "titan.uv"

local path = root .. "/" .. scenario .. ".dat"
uv.__test_fs_reset_counters()

if scenario == "prepare" then
    uv.__test_fs_fail_next_prepare("fs.write")
    uv.run(function()
        fs.write_file(path, "never-submitted")
    end)

    local ok, err = pcall(uv.loop)
    assert(not ok)
    assert(tostring(err):find(
        "injected filesystem prepare failure", 1, true), tostring(err))
    -- The open and cancellation-driven close are the only native requests.
    -- In particular, no fake submitted write owner survives the failed
    -- allocating preparation.
    assert(uv.__test_fs_submission_count() == 2)
    assert(uv.__test_fs_cleanup_count() == 2)
    assert(uv.__test_fs_current_active() == 0)

    local later = uv.run(function()
        timer.yield()
        return 19
    end)
    uv.loop()
    assert(later:join() == 19)
    assert(os.remove(path))
    print("RESULT pre-submit filesystem failure left no owner")
elseif scenario == "partial-prepare" then
    uv.__test_fs_set_max_write_chunk(3)
    uv.__test_fs_fail_prepare_after("fs.write", 1)
    uv.run(function()
        fs.write_file(path, "abcdefghij")
    end)

    local ok, err = pcall(uv.loop)
    assert(not ok)
    assert(tostring(err):find(
        "injected filesystem prepare failure", 1, true), tostring(err))
    -- open + the first short write + fatal cleanup close. The second write
    -- owner was never published, so no callback/cleanup is fabricated for it.
    assert(uv.__test_fs_submission_count() == 3)
    assert(uv.__test_fs_cleanup_count() == 3)
    assert(uv.__test_fs_current_active() == 0)

    local later = uv.run(function()
        local data = fs.read_file(path)
        fs.unlink(path)
        return data
    end)
    uv.loop()
    assert(later:join() == "abc")
    print("RESULT partial-write resubmit preparation left no owner")
elseif scenario == "close" then
    local limit = uv.__test_fs_close_retry_limit()
    uv.__test_fs_force_close_callback_errors(limit)
    uv.run(function()
        fs.write_file(path, "bounded-close")
    end)

    local ok, err = pcall(uv.loop)
    assert(not ok)
    assert(err.operation == "fs.close", tostring(err))
    -- open + write + the bounded number of physical close attempts.
    assert(uv.__test_fs_submission_count() == 2 + limit)
    assert(uv.__test_fs_cleanup_count() == 2 + limit)
    assert(uv.__test_fs_current_active() == 0)

    -- The loop itself was closed, while the failed File/Runtime remain rooted
    -- and terminal. A repeated drive reports the saved failure without
    -- entering libuv again.
    local again_ok, again_err = pcall(uv.loop)
    assert(not again_ok and again_err == err)
    assert(os.remove(path))
    print("RESULT persistent close failure stopped after bounded retries")
else
    error("unknown terminal fault scenario: " .. scenario)
end
