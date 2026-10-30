local assert = require "luassert"
local progress = require "titan-compiler.progress"
local terminal = require "spec.support.terminal_screen"

-- The reporter's writer, clock and terminal width are injected, so both
-- renderers are exercised without a terminal.
local function capture(options)
    local written = {}
    options = options or {}
    local reporter = progress.new(options.kind or progress.PLAIN, {
        writer = function(text) written[#written + 1] = text end,
        now = options.now or function() return 0 end,
        width = options.width,
        columns = options.columns,
        uv = options.uv,
        locale = options.locale,
        windows = options.windows,
        term = options.term,
        tty = options.tty,
        no_color = options.no_color,
    })
    return reporter, function() return table.concat(written) end, written
end

-- Visible text of one rendered line: styling and cursor control removed.
local function plain_text(text)
    return (text:gsub("\27%[[%d;]*%a", ""))
end

-- Visible column count of one line: escape sequences and UTF-8 continuation
-- bytes are not columns.
local function columns(text)
    local count = 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte < 0x80 or byte >= 0xC0 then count = count + 1 end
    end
    return count
end

describe("progress mode selection", function()
    it("keeps the historical output for -q", function()
        assert.equal(progress.NULL, progress.select({ quiet = true }))
        assert.equal(progress.NULL,
            progress.select({ quiet = true, verbose = true, tty = true }))
    end)

    it("renders verbose output with the plain renderer", function()
        assert.equal(progress.PLAIN, progress.select({ verbose = true }))
        assert.equal(progress.PLAIN, progress.select({ verbose = true, tty = true }))
    end)

    it("renders a non-terminal with the plain renderer", function()
        assert.equal(progress.PLAIN, progress.select({ tty = false }))
        assert.equal(progress.PLAIN, progress.select({}))
    end)

    it("refuses the live renderer for a dumb terminal", function()
        assert.equal(progress.LIVE, progress.select({ tty = true, term = "xterm-256color" }))
        assert.equal(progress.PLAIN, progress.select({ tty = true, term = "dumb" }))
    end)

    it("refuses the live renderer beside a parent make jobserver", function()
        assert.equal(progress.PLAIN, progress.select({
            tty = true, term = "xterm", makeflags = "-j8 --jobserver-auth=3,4",
        }))
        assert.equal(progress.PLAIN, progress.select({
            tty = true, term = "xterm", makeflags = "--jobserver-fds=3,4 -j",
        }))
        -- An ordinary -j carries no shared terminal region.
        assert.equal(progress.LIVE, progress.select({
            tty = true, term = "xterm", makeflags = "-j8",
        }))
    end)
end)

describe("progress glyphs and colour", function()
    it("chooses Unicode only for a UTF-8 locale on Unix", function()
        local unicode = progress.glyphs({ locale = "en_US.UTF-8" })
        assert.equal("✓", unicode.ok)
        assert.equal("✗", unicode.failed)
        assert.equal(" · ", unicode.separator)
        assert.equal(10, #unicode.spinner)

        local ascii = progress.glyphs({ locale = "C" })
        assert.equal("ok", ascii.ok)
        assert.equal("FAILED", ascii.failed)
        assert.equal(" | ", ascii.separator)
        assert.same({ "-", "\\", "|", "/" }, ascii.spinner)

        assert.equal("ok", progress.glyphs({ locale = "en_US.UTF-8", windows = true }).ok)
    end)

    it("resolves the locale chain most specific first", function()
        assert.equal("C.UTF-8", progress.locale({
            LC_ALL = "C.UTF-8", LC_CTYPE = "C", LANG = "C",
        }))
        assert.equal("C", progress.locale({ LC_ALL = "", LC_CTYPE = "C", LANG = "en_US.UTF-8" }))
        assert.equal("en_US.UTF-8", progress.locale({ LANG = "en_US.UTF-8" }))
        assert.is_nil(progress.locale({}))
        assert.is_nil(progress.locale(nil))
    end)

    it("enables colour only on an escape-capable terminal without NO_COLOR", function()
        assert.is_false(progress.colour({ tty = false, term = "xterm" }))
        assert.is_false(progress.colour({ tty = true, term = "dumb" }))
        assert.is_true(progress.colour({ tty = true, term = "xterm" }))
        -- NO_COLOR disables colour only; an empty value keeps it enabled.
        assert.is_false(progress.colour({ tty = true, term = "xterm", no_color = "1" }))
        assert.is_true(progress.colour({ tty = true, term = "xterm", no_color = "" }))
    end)

    it("reports zero for a negative or undefined time", function()
        assert.equal("0.0s", progress.duration(-5))
        assert.equal("0.0s", progress.duration(0 / 0))
        assert.equal("0:00", progress.clock(-5))
        assert.equal("0:00", progress.clock(0 / 0))
    end)

    it("names a final link by its output basename", function()
        assert.equal("app.so", progress.basename("/out/app.so"))
        assert.equal("app.so", progress.basename("app.so/"))
        assert.equal("app.exe", progress.basename("C:\\out\\app.exe"))
        -- A spelling with no remaining component is kept as given.
        assert.equal("//", progress.basename("//"))
    end)

    it("formats elapsed times and the footer clock", function()
        assert.equal("3.4s", progress.duration(3.44))
        assert.equal("14.2s", progress.duration(14.25))
        assert.equal("1m12s", progress.duration(72))
        assert.equal("2h05m", progress.duration(7500))
        assert.equal("0:23", progress.clock(23))
        assert.equal("12:05", progress.clock(725))
        assert.equal("1:02:03", progress.clock(3723))
    end)
end)

describe("the null renderer", function()
    it("writes nothing at all", function()
        local reporter, written = capture({ kind = progress.NULL })
        reporter:plan(3)
        reporter:module_begin("app.one")
        reporter:module_phase("app.one", "checking")
        reporter:up_to_date()
        reporter:up_to_date_drained()
        reporter:source_begin("helper.c")
        reporter:source_done("helper.c")
        reporter:source_up_to_date()
        reporter:link_begin("app.so")
        reporter:link_up_to_date("app.so")
        reporter:link_done("app.so")
        reporter:module_done("app.one")
        reporter:module_failed("app.two")
        reporter:write("diagnostic\n")
        reporter:finish()
        assert.equal("", written())
    end)
end)

describe("the plain renderer", function()
    it("pads names to a common column and ends a phase on the next begin", function()
        local reporter, written = capture()
        reporter:module_begin("titan.json")
        reporter:module_phase("titan.json", "parsing")
        reporter:module_phase("titan.json", "checking")
        reporter:module_phase("titan.json", "generating C")
        reporter:module_phase("titan.json", "compiling C", "2 parts")
        reporter:module_done("titan.json")
        assert.equal(table.concat({
            "titan.json ............... parsing",
            "titan.json ............... checking",
            "titan.json ............... generating C",
            "titan.json ............... compiling C (2 parts)",
            "titan.json ............... done 0.0s",
            "",
        }, "\n"), written())
    end)

    it("keeps at least three dots for a name past the column", function()
        local reporter, written = capture()
        local long = string.rep("m", 40)
        reporter:module_begin(long)
        reporter:module_phase(long, "parsing")
        assert.equal(long .. " ... parsing\n", written())
    end)

    it("states the single up-to-date summary once decisions drained", function()
        local reporter, written = capture()
        reporter:up_to_date()
        reporter:up_to_date()
        reporter:up_to_date_drained()
        reporter:up_to_date_drained()
        assert.equal("2 modules up to date\n", written())

        local single, single_written = capture()
        single:up_to_date()
        single:up_to_date_drained()
        assert.equal("1 module up to date\n", single_written())

        local none, none_written = capture()
        none:up_to_date_drained()
        assert.equal("", none_written())
    end)

    it("reports link and authored C source steps", function()
        local reporter, written = capture({ now = (function()
            local clock = 0
            return function() return clock end
        end)() })
        reporter:source_begin("helper.c")
        reporter:source_done("helper.c")
        reporter:source_up_to_date()
        reporter:link_begin("app.so")
        reporter:link_done("app.so")
        assert.equal(table.concat({
            "helper.c ................. compiling C source",
            "helper.c ................. done 0.0s",
            "app.so ................... linking",
            "app.so ................... done 0.0s",
            "",
        }, "\n"), written())
    end)

    it("writes a completed row that exactly fills the width", function()
        local function row_at(width)
            local reporter, written = capture({
                kind = progress.LIVE, locale = "C", width = width,
            })
            reporter:module_begin("abcdefghijklm")
            local first = written():match("^[^\r\n]+")
            reporter:finish()
            return plain_text(first)
        end
        local natural = row_at(200)
        local exact = row_at(columns(natural))
        assert.equal(natural, exact)
    end)

    it("writes through stderr when no writer is injected", function()
        local captured = {}
        local saved = io.stderr
        io.stderr = {
            write = function(_, ...)
                for index = 1, select("#", ...) do
                    captured[#captured + 1] = tostring(select(index, ...))
                end
                return true
            end,
            flush = function() return true end,
        }
        local called, failure = pcall(function()
            local reporter = progress.new(progress.PLAIN, {
                now = function() return 0 end,
            })
            reporter:module_begin("app.one")
            reporter:module_phase("app.one", "parsing")
        end)
        io.stderr = saved
        assert.truthy(called, failure)
        assert.equal("app.one .................. parsing\n",
            table.concat(captured))
    end)

    it("reports a certificate hit as up to date", function()
        local reporter, written = capture()
        reporter:link_up_to_date("app.so")
        assert.equal("app.so ................... up to date\n", written())
    end)

    it("never counts a certificate hit as a link in the summary", function()
        local reporter, written = capture()
        reporter:up_to_date()
        reporter:link_up_to_date("app.so")
        reporter:finish()
        assert.equal(table.concat({
            "app.so ................... up to date",
            "Finished in 0.0s: 1 up to date, app.so up to date",
            "",
        }, "\n"), written())
    end)

    it("finishes with one summary of compiled, up to date and linked", function()
        local clock = 0
        local reporter, written = capture({ now = function() return clock end })
        reporter:module_begin("app.one")
        clock = 1.5
        reporter:module_done("app.one")
        reporter:up_to_date()
        reporter:source_up_to_date()
        reporter:link_begin("app.so")
        clock = 6.1
        reporter:link_done("app.so")
        clock = 72
        reporter:finish()
        assert.equal(table.concat({
            "app.one .................. done 1.5s",
            "app.so ................... linking",
            "app.so ................... done 4.6s",
            "Finished in 1m12s: 1 compiled, 1 up to date, " ..
                "1 C source up to date, linked app.so",
            "",
        }, "\n"), written())
    end)

    it("reports a failure before the diagnostics", function()
        local clock = 0
        local reporter, written = capture({ now = function() return clock end })
        reporter:module_begin("app.one")
        reporter:module_phase("app.one", "checking")
        clock = 14.25
        reporter:module_failed("app.one")
        reporter:fail()
        reporter:write("app.one.titan:2:10: type error\n")
        assert.equal(table.concat({
            "app.one .................. checking",
            "app.one .................. failed",
            "Failed after 14.2s",
            "app.one.titan:2:10: type error",
            "",
        }, "\n"), written())
    end)

    it("stays silent for an invocation that reported no event", function()
        local reporter, written = capture()
        reporter:fail()
        assert.equal("", written())
    end)
end)

describe("the live renderer", function()
    local function live(options)
        options = options or {}
        return capture({
            kind = progress.LIVE,
            locale = options.locale or "en_US.UTF-8",
            width = options.width or 80,
            tty = options.tty,
            now = options.now,
        })
    end

    it("draws a transient region and parks the cursor at its start", function()
        local reporter, written = live()
        reporter:plan(2)
        reporter:module_begin("app.one")
        -- The first frame needs no erase: nothing is on screen yet.
        local first = written()
        assert.truthy(first:find("app.one", 1, true), first)
        assert.truthy(first:find("[0/2] 1 running", 1, true), first)
        -- Two rows (the active module and the footer) return one line up.
        assert.truthy(first:find("\r\27[1A", 1, true), first)
        -- Every later frame erases the region before drawing it again.
        reporter:module_phase("app.one", "checking")
        local text = written():sub(#first + 1)
        assert.truthy(text:find("\27[J", 1, true), text)
        assert.truthy(text:find("checking", 1, true), text)
    end)

    it("moves a finished module into the scrollback", function()
        local clock = 0
        local reporter, written = live({ now = function() return clock end })
        reporter:plan(2)
        reporter:module_begin("app.one")
        clock = 1.2
        reporter:module_done("app.one")
        local text = written()
        -- The finished row is persistent and carries its elapsed time.
        assert.truthy(text:find("✓ app.one", 1, true), text)
        assert.truthy(text:find("1.2s", 1, true), text)
        assert.truthy(text:find("[1/2] 0 running", 1, true), text)
    end)

    it("leaves a failed module row in the scrollback", function()
        local clock = 0
        local reporter, written = capture({
            kind = progress.LIVE, locale = "C", width = 80,
            now = function() return clock end,
        })
        reporter:module_begin("app.two")
        clock = 1.6
        reporter:module_failed("app.two")
        local screen = terminal.render(written())
        local rendered = table.concat(screen, "\n")
        assert.is_true(terminal.shows(screen, "FAILED app.two"), rendered)
        assert.is_true(terminal.shows(screen, "failed"), rendered)
        -- A failed row states the outcome instead of an elapsed time.
        assert.is_nil(rendered:find("1.6s", 1, true), rendered)
    end)

    it("leaves an up-to-date link row in the scrollback", function()
        local reporter, written = capture({
            kind = progress.LIVE, locale = "C", width = 80,
        })
        reporter:link_up_to_date("app.so")
        local screen = terminal.render(written())
        local rendered = table.concat(screen, "\n")
        assert.is_true(terminal.shows(screen, "ok app.so"), rendered)
        assert.is_true(terminal.shows(screen, "up to date"), rendered)
    end)

    it("reports a failed authored C source step in both renderers", function()
        local reporter, written = capture()
        reporter:source_begin("helper.c")
        reporter:source_failed("helper.c")
        assert.equal(table.concat({
            "helper.c ................. compiling C source",
            "helper.c ................. failed",
            "",
        }, "\n"), written())

        local live_reporter, live_written = capture({
            kind = progress.LIVE, locale = "C", width = 80,
        })
        live_reporter:source_begin("helper.c")
        live_reporter:source_failed("helper.c")
        local screen = terminal.render(live_written())
        assert.is_true(terminal.shows(screen, "FAILED helper.c"),
            table.concat(screen, "\n"))
    end)

    it("shows the phase and elapsed time on the active row", function()
        local clock = 0
        local reporter, written = live({ now = function() return clock end })
        reporter:module_begin("app.one")
        clock = 5.1
        reporter:module_phase("app.one", "compiling C", "2 parts")
        assert.truthy(written():find("compiling C 2 parts", 1, true), written())
        assert.truthy(written():find("5.1s", 1, true), written())
        -- Nothing clears the phase: `compiling C` is the last one before
        -- `done`, and a record without a phase name reports nothing.
        local before = written()
        reporter:module_phase("app.one", nil)
        assert.equal(before, written())
        clock = 6.2
        reporter:module_done("app.one")
        assert.truthy(written():find("6.2s", 1, true), written())
    end)

    it("falls back to an exported terminal-width hint", function()
        local reporter, written = capture({
            kind = progress.LIVE, locale = "C", width = nil, columns = "40",
        })
        reporter:module_begin("app." .. string.rep("x", 80))
        for line in written():gmatch("[^\r\n]+") do
            local visible = plain_text(line)
            assert.is_true(columns(visible) <= 40, visible)
        end
        -- Nothing known at all still truncates to the 80-column default.
        local fallback, fallback_written = capture({
            kind = progress.LIVE, locale = "C",
        })
        fallback:module_begin("app." .. string.rep("x", 120))
        for line in fallback_written():gmatch("[^\r\n]+") do
            assert.is_true(columns(plain_text(line)) <= 80, line)
        end
    end)

    it("truncates every row to the terminal width", function()
        local reporter, written = live({ width = 24 })
        reporter:plan(1)
        reporter:module_begin("app.a-very-long-module-name")
        reporter:module_phase("app.a-very-long-module-name", "compiling C", "4 parts")
        local text = written()
        assert.truthy(text:find("⠋", 1, true), text)
        for line in text:gmatch("[^\r\n]+") do
            local visible = plain_text(line)
            assert.is_true(columns(visible) <= 24, visible)
        end
    end)

    it("writes other stderr text above the region", function()
        local reporter, written = live()
        reporter:module_begin("app.one")
        reporter:write("the C compiler complained\n")
        local text = written()
        assert.truthy(
            text:find("\r\27[Jthe C compiler complained\n", 1, true), text)
        -- The region is drawn again after the text.
        local tail = text:sub((text:find("the C compiler complained", 1, true)))
        assert.truthy(tail:find("app.one", 1, true), tail)
    end)

    it("erases the region before the summary and after a failure", function()
        local clock = 0
        local reporter, written = live({ now = function() return clock end })
        reporter:module_begin("app.one")
        clock = 14.25
        reporter:module_done("app.one")
        reporter:finish()
        local text = written()
        local tail = text:sub(-64)
        assert.truthy(tail:find("\r\27[JFinished in 14.2s: 1 compiled\n", 1, true),
            tail)

        local failing, failing_written = live()
        failing:module_begin("app.one")
        failing:fail()
        local failure = failing_written()
        assert.truthy(failure:find("\r\27[JFailed after 0.0s\n", 1, true), failure)
    end)

    it("keeps colour out of the region when it is disabled", function()
        local reporter, written = live({ tty = false })
        reporter:module_begin("app.one")
        local text = written()
        assert.is_nil(text:find("\27[36m", 1, true))
        assert.is_nil(text:find("\27[1m", 1, true))
        assert.truthy(text:find("⠋", 1, true), text)
    end)

    it("reports the real window size from a private terminal handle", function()
        local size_calls = 0
        local closed = false
        local handle = {
            get_winsize = function()
                size_calls = size_calls + 1
                return 40, 20
            end,
            close = function() closed = true end,
        }
        local opened_fd, wrapped_fd, wrapped_readable
        local uv = {
            hrtime = function() return 0 end,
            run = function() return 0 end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            fs_open = function(path, mode, permissions)
                assert.equal("/dev/tty", path)
                opened_fd = 7
                return opened_fd
            end,
            new_tty = function(fd, readable)
                wrapped_fd, wrapped_readable = fd, readable
                return handle
            end,
        }
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "en_US.UTF-8",
            writer = function() end,
            now = function() return 0 end,
        })
        -- The private descriptor is wrapped, never fd 2.
        assert.equal(7, opened_fd)
        assert.equal(7, wrapped_fd)
        assert.is_true(wrapped_readable)
        -- The width is asked again on every frame.
        reporter:module_begin("app.one")
        assert.equal(40, reporter:width())
        reporter:tick()
        assert.truthy(size_calls >= 2, size_calls)
        reporter:finish()
        assert.is_true(closed)
    end)

    it("falls back to COLUMNS and then to 80 without a terminal handle", function()
        local uv = {
            hrtime = function() return 0 end,
            run = function() return 0 end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            fs_open = function() return nil, "no controlling terminal" end,
        }
        local hinted = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "en_US.UTF-8", columns = "46",
            writer = function() end, now = function() return 0 end,
        })
        assert.equal(46, hinted:width())
        hinted:finish()

        local plain = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "en_US.UTF-8",
            writer = function() end, now = function() return 0 end,
        })
        assert.equal(80, plain:width())
        plain:finish()
    end)

    it("prefers an injected width over every terminal handle", function()
        local handle = { get_winsize = function() return 40, 20 end,
            close = function() end }
        local uv = {
            hrtime = function() return 0 end,
            run = function() return 0 end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            fs_open = function() return 9 end,
            new_tty = function() return handle end,
        }
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "en_US.UTF-8", columns = "46", width = 33,
            writer = function() end, now = function() return 0 end,
        })
        assert.equal(33, reporter:width())
        reporter:finish()
    end)

    it("closes the private descriptor when the terminal handle cannot wrap it", function()
        local closed
        local uv = {
            hrtime = function() return 0 end,
            run = function() return 0 end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            fs_open = function() return 11 end,
            new_tty = function() return nil, "not a terminal" end,
            fs_close = function(fd) closed = fd; return true end,
        }
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "C", columns = "64", writer = function() end,
            now = function() return 0 end,
        })
        assert.equal(11, closed)
        assert.equal(64, reporter:width())
        reporter:finish()
    end)

    it("falls back when the console cannot report its size", function()
        local handle = {
            get_winsize = function() error("not a console") end,
            close = function() end,
        }
        local uv = {
            hrtime = function() return 0 end,
            run = function() return 0 end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            fs_open = function() return 9 end,
            new_tty = function() return handle end,
        }
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "C", columns = "58", writer = function() end,
            now = function() return 0 end,
        })
        assert.equal(58, reporter:width())
        reporter:finish()
    end)

    it("falls back to a monotonic clock when none is injected", function()
        local ticks = 0
        local uv = {
            hrtime = function() ticks = ticks + 1000000000; return ticks end,
            run = function() return 0 end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            fs_open = function() return nil, "no controlling terminal" end,
        }
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "C", writer = function() end,
        })
        assert.equal(1, reporter:elapsed())
        assert.equal(2, reporter:elapsed())
        reporter:finish()
        -- No platform clock at all still measures something.
        local bare = progress.new(progress.PLAIN, { writer = function() end })
        assert.is_true(bare:elapsed() >= 0)
    end)

    it("repaints the active region on the animation timer", function()
        local uv = require("titan-compiler.process").library()
        local written = {}
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "C", width = 80,
            writer = function(text) written[#written + 1] = text end,
        })
        reporter:module_begin("app.one")
        local before = #written
        -- The animation timer is unref'd, so keep the loop alive just long
        -- enough to observe one frame.
        local keepalive = uv.new_timer()
        local started = uv.hrtime()
        keepalive:start(250, 0, function() keepalive:close() end)
        while #written == before and (uv.hrtime() - started) < 2000000000 do
            uv.run("once")
        end
        -- Record the observation before any cleanup write can satisfy it.
        local repainted = #written > before
        if not keepalive:is_closing() then
            keepalive:stop()
            keepalive:close()
        end
        reporter:finish()
        assert.truthy(repainted, "the timer never repainted the region")
    end)

    it("uses the ASCII separator with ASCII glyphs", function()
        local reporter, written = capture({
            kind = progress.LIVE, locale = "C", width = 80,
        })
        reporter:plan(2)
        reporter:module_begin("app.one")
        reporter:up_to_date()
        local text = written()
        -- A restored module is a completed decision, so it advances the
        -- footer's numerator as well as the up-to-date count.
        assert.truthy(text:find("[1/2] 1 running | 1 up to date | 0:00", 1, true),
            text)
        -- No UTF-8 byte leaks into an ASCII region.
        assert.is_nil(text:find("\194\183", 1, true))
    end)

    it("counts restored modules in the footer's completed numerator", function()
        local reporter, written = capture({
            kind = progress.LIVE, locale = "C", width = 80,
        })
        reporter:plan(3)
        reporter:up_to_date()
        reporter:up_to_date()
        reporter:module_begin("app.three")
        reporter:module_done("app.three")
        local text = written()
        assert.truthy(text:find("[3/3] 0 running | 2 up to date | 0:00", 1, true),
            text)

        -- An all-hit build reaches the total without compiling anything.
        local hits, hits_written = capture({
            kind = progress.LIVE, locale = "C", width = 80,
        })
        hits:plan(2)
        hits:up_to_date()
        hits:up_to_date()
        local hit_text = hits_written()
        assert.truthy(hit_text:find("[2/2] 0 running | 2 up to date | 0:00", 1, true),
            hit_text)
    end)

    it("terminates a write without a newline so the next step cannot erase it", function()
        local clock = 0
        local reporter, written = capture({
            kind = progress.LIVE, locale = "en_US.UTF-8", width = 80,
            now = function() return clock end,
        })
        reporter:module_begin("app.one")
        reporter:link_begin("app.so")
        -- A captured child log that does not end in a newline (both streams).
        reporter:write("link denied out")
        reporter:write("link denied err")
        clock = 1.4
        reporter:link_failed("app.so")
        local screen = terminal.render(written())
        assert.is_true(terminal.shows(screen, "link denied out"),
            table.concat(screen, "\n"))
        assert.is_true(terminal.shows(screen, "link denied err"),
            table.concat(screen, "\n"))
        assert.is_true(terminal.shows(screen, "failed"),
            table.concat(screen, "\n"))
    end)

    it("writes a Unix live region through blocking stderr, never a libuv tty", function()
        local written = {}
        local tty_calls = 0
        local uv = {
            hrtime = function() return 0 end,
            run = function() return 0 end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            new_tty = function()
                tty_calls = tty_calls + 1
                error("a Unix live reporter must not reopen fd 2")
            end,
        }
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = false, tty = true, term = "xterm",
            locale = "en_US.UTF-8",
            writer = function(text) written[#written + 1] = text end,
            now = function() return 0 end,
            width = 80,
        })
        assert.equal(0, tty_calls)
        reporter:module_begin("app.one")
        -- One large write is delivered whole through the blocking sink.
        local payload = string.rep("diagnostic line\n", 12000) .. "END-OF-DIAGNOSTICS"
        reporter:write(payload)
        reporter:finish()
        local text = table.concat(written)
        assert.truthy(text:find(payload, 1, true), "the large write was truncated")
        assert.equal(0, tty_calls)
    end)

    it("delivers every queued Windows console write before the summary", function()
        local accepted = false
        local queued, callbacks = {}, {}
        local tty = {
            try_write = function(_, text)
                if accepted then return #text end
                return 0
            end,
            write = function(_, text, callback)
                queued[#queued + 1] = text
                callbacks[#callbacks + 1] = callback
                return true
            end,
            get_winsize = function() return 120, 40 end,
        }
        local runs = 0
        local uv = {
            hrtime = function() return 0 end,
            new_tty = function() return tty end,
            new_timer = function()
                return { start = function() end, stop = function() end,
                    close = function() end, unref = function() end }
            end,
            run = function()
                runs = runs + 1
                local callback = table.remove(callbacks, 1)
                if callback then callback() end
                return 0
            end,
        }
        local reporter = progress.new(progress.LIVE, {
            uv = uv, windows = true, tty = true, term = "xterm",
            locale = "en_US.UTF-8",
            writer = function() error("the Windows sink must use the console") end,
            now = function() return 0 end,
        })
        assert.equal(tty, reporter.tty)
        -- The console accepts nothing yet: the frame is queued and drained.
        reporter:module_begin("app.one")
        assert.equal(0, reporter.pending)
        assert.truthy(runs > 0)
        assert.truthy(#queued > 0)

        -- A frame drawn from the timer callback must not run the loop again.
        local runs_before = runs
        reporter:tick()
        assert.equal(runs_before, runs)
        assert.truthy(reporter.pending > 0)

        -- Ordinary code drains what the callback left queued, and the final
        -- message is delivered last.
        accepted = true
        reporter:write("after the frame\n")
        assert.equal(0, reporter.pending)
        assert.truthy(runs > runs_before)
        reporter:finish()
        assert.equal(0, reporter.pending)
    end)

    it("styles the region when colour is enabled", function()
        local reporter, written = live({ tty = true, locale = "en_US.UTF-8" })
        reporter:module_begin("app.one")
        local text = written()
        assert.truthy(text:find("\27[36m⠋", 1, true), text)
        assert.truthy(text:find("\27[1mapp.one\27[0m", 1, true), text)
    end)
end)
