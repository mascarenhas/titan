local assert = require "luassert"
local progress = require "titan-compiler.progress"

-- The reporter's writer, clock and terminal width are injected, so both
-- renderers are exercised without a terminal.
local function capture(options)
    local written = {}
    options = options or {}
    local reporter = progress.new(options.kind or progress.PLAIN, {
        writer = function(text) written[#written + 1] = text end,
        now = options.now or function() return 0 end,
        width = options.width,
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
        assert.equal(10, #unicode.spinner)

        local ascii = progress.glyphs({ locale = "C" })
        assert.equal("ok", ascii.ok)
        assert.equal("FAILED", ascii.failed)
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

    it("reports a certificate hit as up to date", function()
        local reporter, written = capture()
        reporter:link_up_to_date("app.so")
        assert.equal("app.so ................... up to date\n", written())
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

    it("shows the phase and elapsed time on the active row", function()
        local clock = 0
        local reporter, written = live({ now = function() return clock end })
        reporter:module_begin("app.one")
        clock = 5.1
        reporter:module_phase("app.one", "compiling C", "2 parts")
        assert.truthy(written():find("compiling C 2 parts", 1, true), written())
        assert.truthy(written():find("5.1s", 1, true), written())
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

    it("styles the region when colour is enabled", function()
        local reporter, written = live({ tty = true, locale = "en_US.UTF-8" })
        reporter:module_begin("app.one")
        local text = written()
        assert.truthy(text:find("\27[36m⠋", 1, true), text)
        assert.truthy(text:find("\27[1mapp.one\27[0m", 1, true), text)
    end)
end)
