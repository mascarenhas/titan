-- titanc progress reporting (issue #322). The compiler library and the
-- language-server API create no reporter: every hook is a no-op without one,
-- and only the CLI selects a renderer. `select` is a pure decision over
-- injected environment and terminal facts; `new` builds a renderer whose
-- writer, clock and terminal width are injectable, so both renderers are
-- unit-tested without a terminal.
-- Implementation notes: doc/implementation/driver.md#the-titanc-command-line
local progress = {}

progress.NULL = "null"    -- -q: exactly the historical output
progress.PLAIN = "plain"  -- non-TTY stderr, or -v: one self-contained line per event
progress.LIVE = "live"    -- TTY stderr: persistent lines plus a transient region

-- Names and their state start at this column; the dots pad a name to it, and
-- a longer name still gets the three-dot minimum separator.
local LINE_COLUMN = 26

-- Live scrollback and active rows share one name column.
local NAME_COLUMN = 24

-- The transient region refreshes on this timer period.
local FRAME_MILLISECONDS = 100

local ESC = "\27["
local STYLES = {
    bold = ESC .. "1m",
    dim = ESC .. "2m",
    green = ESC .. "32m",
    red = ESC .. "31m",
    cyan = ESC .. "36m",
}
local RESET = ESC .. "0m"

local UNICODE_SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ASCII_SPINNER = { "-", "\\", "|", "/" }

--
-- Pure decisions
--

-- Parallel make siblings share the terminal, so their live regions would
-- overwrite each other. The jobserver advertisement is the signal.
local function serves_jobserver(makeflags)
    if type(makeflags) ~= "string" then return false end
    return makeflags:find("jobserver-auth", 1, true) ~= nil or
        makeflags:find("jobserver-fds", 1, true) ~= nil
end

-- The renderer kind, a pure function of the injected inputs. `quiet` wins
-- over `verbose`, although the CLI rejects that combination as a usage error
-- before selecting anything.
function progress.select(options)
    options = options or {}
    if options.quiet then return progress.NULL end
    if options.verbose then return progress.PLAIN end
    if not options.tty then return progress.PLAIN end
    if options.term == "dumb" then return progress.PLAIN end
    if serves_jobserver(options.makeflags) then return progress.PLAIN end
    return progress.LIVE
end

-- The locale chain (`LC_ALL`, then `LC_CTYPE`, then `LANG`), first non-empty.
function progress.locale(environment)
    for _, name in ipairs({ "LC_ALL", "LC_CTYPE", "LANG" }) do
        local value = type(environment) == "table" and environment[name]
        if type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function names_utf8(locale)
    if type(locale) ~= "string" then return false end
    return locale:match("[Uu][Tt][Ff]%-?8") ~= nil
end

-- Glyphs: Unicode on Unix when the locale names UTF-8, ASCII otherwise and
-- always on Windows.
function progress.glyphs(options)
    options = options or {}
    if options.windows or not names_utf8(options.locale) then
        return {
            unicode = false, spinner = ASCII_SPINNER,
            ok = "ok", failed = "FAILED",
        }
    end
    return {
        unicode = true, spinner = UNICODE_SPINNER,
        ok = "✓", failed = "✗",
    }
end

-- Colour needs a terminal that understands escapes. NO_COLOR (no-color.org)
-- disables colour only; it never disables live updates.
function progress.colour(options)
    options = options or {}
    if not options.tty then return false end
    if options.term == "dumb" then return false end
    local no_color = options.no_color
    if type(no_color) == "string" and no_color ~= "" then return false end
    return true
end

-- "3.4s", "1m12s", "2h05m".
function progress.duration(seconds)
    if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
        seconds = 0
    end
    if seconds < 60 then
        return string.format("%.1fs", seconds)
    elseif seconds < 3600 then
        return string.format("%dm%02ds", math.floor(seconds / 60),
            math.floor(seconds % 60))
    end
    return string.format("%dh%02dm", math.floor(seconds / 3600),
        math.floor(seconds % 3600 / 60))
end

-- "0:23", "12:05", "1:02:03": the footer clock.
function progress.clock(seconds)
    if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
        seconds = 0
    end
    seconds = math.floor(seconds)
    if seconds < 3600 then
        return string.format("%d:%02d", math.floor(seconds / 60),
            seconds % 60)
    end
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600),
        math.floor(seconds % 3600 / 60), seconds % 60)
end

-- A final link is reported by its output's basename.
function progress.basename(path)
    local name = tostring(path):gsub("[/\\]+$", ""):match("([^/\\]+)$")
    return name or tostring(path)
end

--
-- Text measurement: escape sequences are never measured, and truncation
-- never splits a UTF-8 sequence.
--

local function codepoint_count(text)
    local count = 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte < 0x80 or byte >= 0xC0 then count = count + 1 end
    end
    return count
end

local function truncate(text, limit)
    if limit <= 0 then return "" end
    local count = 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte < 0x80 or byte >= 0xC0 then
            count = count + 1
            if count > limit then return text:sub(1, index - 1) end
        end
    end
    return text
end

-- A line is a list of { text, style } pieces; styling is optional, and the
-- visible width is counted on the plain text alone.
local function render(pieces, width, colour)
    local out, used = {}, 0
    for _, piece in ipairs(pieces) do
        if width and used >= width then break end
        local text = piece[1]
        if width and codepoint_count(text) > width - used then
            text = truncate(text, width - used)
        end
        if text ~= "" then
            local style = piece[2]
            if style and colour then
                out[#out + 1] = STYLES[style]
                out[#out + 1] = text
                out[#out + 1] = RESET
            else
                out[#out + 1] = text
            end
            used = used + codepoint_count(text)
        end
    end
    return table.concat(out)
end

local function padding(name, column)
    local used = codepoint_count(name)
    if used >= column then return " " end
    return string.rep(" ", column - used)
end

--
-- Reporter
--

local Reporter = {}
Reporter.__index = Reporter

local function default_writer(text)
    io.stderr:write(text)
    io.stderr:flush()
end

-- Options: `writer(text)` replaces stderr, `now()` returns seconds,
-- `width()` returns the terminal width (or is the width itself), `uv` is the
-- live platform library (the timer and the TTY writer; without it the live
-- renderer only writes through `writer`), and `windows`, `locale`, `tty`,
-- `term`, `no_color` describe the environment the CLI observed.
function progress.new(kind, options)
    options = options or {}
    kind = kind or progress.NULL
    local uv = options.uv
    local self = setmetatable({
        kind = kind,
        glyphs = progress.glyphs(options),
        colour = progress.colour(options),
        writer = options.writer or default_writer,
        -- Wall clock, not CPU time: most of a build waits on children.
        now = options.now or function()
            if uv and uv.hrtime then return uv.hrtime() / 1e9 end
            return os.clock()
        end,
        width_of = options.width,
        started = nil,
        active = {}, order = {}, total = nil,
        completed = 0, compiled = 0, up_to_date_count = 0,
        up_to_date_printed = 0, sources_up_to_date = 0, links = {},
        frame = 0, events = 0, drawn = false, closed = false,
    }, Reporter)
    self.started = self.now()
    if self.kind == progress.LIVE then
        if uv then
            local opened, tty = pcall(uv.new_tty, 2, false)
            if opened and tty then self.tty = tty end
        end
        self.sink = self.tty and function(text) self.tty:write(text) end
            or self.writer
        if uv then
            local opened, timer = pcall(uv.new_timer)
            if opened and timer then
                self.timer = timer
                timer:start(FRAME_MILLISECONDS, FRAME_MILLISECONDS, function()
                    pcall(self.tick, self)
                end)
                -- An animation never keeps the loop alive.
                if timer.unref then timer:unref() end
            end
        end
    end
    return self
end

-- Text goes to stderr: the plain writer, or the live terminal sink.
function Reporter:out(text)
    if self.kind == progress.LIVE then
        self.sink(text)
    else
        self.writer(text)
    end
end

function Reporter:elapsed()
    local now = self.now()
    if not self.started then self.started = now end
    local elapsed = now - self.started
    if elapsed < 0 then elapsed = 0 end
    return elapsed
end

function Reporter:width()
    if type(self.width_of) == "number" then return self.width_of end
    if self.width_of then return self.width_of() end
    if self.tty and self.tty.get_winsize then
        local called, width = pcall(self.tty.get_winsize, self.tty)
        if called and type(width) == "number" and width > 0 then return width end
    end
    return 80
end

-- One plain line: the name padded to a common column, then its state.
function Reporter:line(name, state)
    local dots = LINE_COLUMN - 1 - codepoint_count(name)
    if dots < 3 then dots = 3 end
    self:out(name .. " " .. string.rep(".", dots) .. " " .. state .. "\n")
end

function Reporter:activate(name, entry)
    entry.name = name
    entry.started = self.now()
    self.active[name] = entry
    if self.kind == progress.LIVE then
        self.order[#self.order + 1] = name
    end
end

function Reporter:deactivate(name)
    local entry = self.active[name]
    if not entry then return nil end
    self.active[name] = nil
    for index, active in ipairs(self.order) do
        if active == name then
            table.remove(self.order, index)
            break
        end
    end
    return entry
end

-- Erase the transient region and leave the cursor in its first column.
function Reporter:erase()
    if self.kind ~= progress.LIVE or not self.drawn then return end
    self:out("\r" .. ESC .. "J")
    self.drawn = false
end

-- The transient region: one row per active module or step, then the footer.
function Reporter:region()
    local width = self:width()
    local lines = {}
    local spinner = self.glyphs.spinner[(self.frame % #self.glyphs.spinner) + 1]
    for _, name in ipairs(self.order) do
        local entry = self.active[name]
        local pieces = {
            { "  " }, { spinner, "cyan" }, { " " },
            { name, "bold" }, { padding(name, NAME_COLUMN) },
        }
        if entry.phase then
            local phase = entry.phase
            if entry.detail then phase = phase .. " " .. entry.detail end
            pieces[#pieces + 1] = { phase, "dim" }
            pieces[#pieces + 1] = { "  " }
        end
        local elapsed = self.now() - entry.started
        if elapsed < 0 then elapsed = 0 end
        pieces[#pieces + 1] = { progress.duration(elapsed), "dim" }
        lines[#lines + 1] = render(pieces, width, self.colour)
    end
    local footer = { "  " }
    if self.total then
        footer[#footer + 1] = "[" .. self.completed .. "/" .. self.total .. "] "
    end
    footer[#footer + 1] = #self.order .. " running"
    if self.up_to_date_count > 0 then
        footer[#footer + 1] = " · " .. self.up_to_date_count .. " up to date"
    end
    footer[#footer + 1] = " · " .. progress.clock(self:elapsed())
    lines[#lines + 1] = render({ { table.concat(footer), "dim" } }, width,
        self.colour)
    return lines
end

-- Erase the region, draw it again, and park the cursor at its start.
function Reporter:redraw()
    if self.kind ~= progress.LIVE or self.closed then return end
    local lines = self:region()
    self:erase()
    self:out(table.concat(lines, "\r\n"))
    if #lines > 1 then
        self:out("\r" .. ESC .. (#lines - 1) .. "A")
    else
        self:out("\r")
    end
    self.drawn = true
end

-- The timer frame: advance the spinner and refresh the visible region.
function Reporter:tick()
    if self.kind ~= progress.LIVE or self.closed then return end
    self.frame = self.frame + 1
    if #self.order == 0 then return end
    self:redraw()
end

-- One finished module or step becomes a persistent line above the region.
function Reporter:scrollback(entry, ok, note)
    local pieces = {
        { "  " },
        { ok and self.glyphs.ok or self.glyphs.failed, ok and "green" or "red" },
        { " " },
        { entry.name, "bold" },
        { padding(entry.name, NAME_COLUMN) },
    }
    if note then
        pieces[#pieces + 1] = { note, "dim" }
    else
        local elapsed = self.now() - entry.started
        if elapsed < 0 then elapsed = 0 end
        pieces[#pieces + 1] = { progress.duration(elapsed), "dim" }
    end
    self:erase()
    self:out(render(pieces, self:width(), self.colour) .. "\r\n")
    self:redraw()
end

-- The module count for the footer.
function Reporter:plan(total)
    if self.kind == progress.NULL then return end
    if math.type(total) == "integer" and total >= 0 then self.total = total end
end

function Reporter:module_begin(name)
    if self.kind == progress.NULL then return end
    self.events = self.events + 1
    self:activate(name, {})
    self:redraw()
end

-- `phase` is nil when the current phase ended without a named successor.
function Reporter:module_phase(name, phase, detail)
    if self.kind == progress.NULL then return end
    if type(phase) ~= "string" then
        local entry = self.active[name]
        if entry and self.kind == progress.LIVE then
            entry.phase, entry.detail = nil, nil
            self:redraw()
        end
        return
    end
    self.events = self.events + 1
    if self.kind == progress.PLAIN then
        return self:line(name, phase .. (detail and (" (" .. detail .. ")") or ""))
    end
    local entry = self.active[name]
    if not entry then return end
    entry.phase, entry.detail = phase, detail
    self:redraw()
end

local function lifetime(entry, now)
    local elapsed = now - entry.started
    if elapsed < 0 then elapsed = 0 end
    return elapsed
end

function Reporter:module_done(name)
    if self.kind == progress.NULL then return end
    self.events = self.events + 1
    self.compiled = self.compiled + 1
    self.completed = self.completed + 1
    local entry = self:deactivate(name)
    if self.kind == progress.PLAIN then
        return self:line(name, "done " ..
            progress.duration(entry and lifetime(entry, self.now()) or 0))
    end
    if entry then self:scrollback(entry, true) end
end

function Reporter:module_failed(name)
    if self.kind == progress.NULL then return end
    self.events = self.events + 1
    self.completed = self.completed + 1
    if self.kind == progress.PLAIN then return self:line(name, "failed") end
    local entry = self:deactivate(name)
    if entry then self:scrollback(entry, false, "failed") end
end

-- One module restored from its certificate: no per-module line, one summary.
function Reporter:up_to_date()
    if self.kind == progress.NULL then return end
    self.events = self.events + 1
    self.up_to_date_count = self.up_to_date_count + 1
    if self.kind == progress.LIVE then self:redraw() end
end

-- Once every decision drained, the plain renderer states the single summary.
function Reporter:up_to_date_drained()
    if self.kind ~= progress.PLAIN then return end
    local count = self.up_to_date_count
    if count == 0 or count == self.up_to_date_printed then return end
    self.up_to_date_printed = count
    self:out(count .. (count == 1 and " module up to date"
        or " modules up to date") .. "\n")
end

local function begin_step(self, name, phase)
    if self.kind == progress.NULL then return end
    self.events = self.events + 1
    if self.kind == progress.PLAIN then self:line(name, phase) end
    -- Both renderers time the step; only the live one draws a row for it.
    self:activate(name, { phase = phase })
    if self.kind == progress.LIVE then self:redraw() end
end

local function end_step(self, name, ok, note)
    if self.kind == progress.NULL then return end
    local entry = self:deactivate(name)
    if self.kind == progress.PLAIN then
        if not ok then return self:line(name, "failed") end
        return self:line(name, "done " ..
            progress.duration(entry and lifetime(entry, self.now()) or 0))
    end
    if entry then self:scrollback(entry, ok, note) end
end

-- A final link: `linking`, then `done <elapsed>`.
function Reporter:link_begin(name)
    begin_step(self, name, "linking")
end

function Reporter:link_done(name)
    if self.kind == progress.NULL then return end
    end_step(self, name, true)
    self.links[#self.links + 1] = name
end

function Reporter:link_failed(name)
    end_step(self, name, false, "failed")
end

-- A final-link certificate hit: `<output> up to date`.
function Reporter:link_up_to_date(name)
    if self.kind == progress.NULL then return end
    self.events = self.events + 1
    self.links[#self.links + 1] = name
    if self.kind == progress.PLAIN then
        return self:line(name, "up to date")
    end
    self:scrollback({ name = name }, true, "up to date")
end

-- An authored C source: `compiling C source`, then `done <elapsed>`.
function Reporter:source_begin(path)
    begin_step(self, path, "compiling C source")
end

function Reporter:source_done(path)
    end_step(self, path, true)
end

function Reporter:source_failed(path)
    end_step(self, path, false, "failed")
end

-- An authored C source restored from its certificate is counted only.
function Reporter:source_up_to_date()
    if self.kind == progress.NULL then return end
    self.events = self.events + 1
    self.sources_up_to_date = self.sources_up_to_date + 1
end

-- Anything else written to stderr, including buffered worker output and the
-- CLI's diagnostics: never inside the region.
function Reporter:write(text)
    if self.kind == progress.NULL then return end
    if type(text) ~= "string" or text == "" then return end
    if self.kind == progress.LIVE and self.drawn and not self.closed then
        self:erase()
        self:out(text)
        if text:sub(-1) ~= "\n" then self:out("\r\n") end
        self:redraw()
    else
        self:out(text)
    end
end

function Reporter:close()
    if self.closed then return end
    self.closed = true
    if self.timer then
        self.timer:stop()
        self.timer:close()
        self.timer = nil
    end
end

local function summary(self)
    local segments = {}
    if self.compiled > 0 then
        segments[#segments + 1] = self.compiled .. " compiled"
    end
    if self.up_to_date_count > 0 then
        segments[#segments + 1] = self.up_to_date_count .. " up to date"
    end
    if self.sources_up_to_date > 0 then
        segments[#segments + 1] = self.sources_up_to_date ..
            (self.sources_up_to_date == 1 and " C source up to date"
                or " C sources up to date")
    end
    if #self.links > 0 then
        segments[#segments + 1] = "linked " .. table.concat(self.links, ", ")
    end
    local text = "Finished in " .. progress.duration(self:elapsed())
    if #segments > 0 then text = text .. ": " .. table.concat(segments, ", ") end
    return text
end

-- The successful end of the invocation: no region remains, one summary line.
-- An invocation that reported no event (a usage error) stays silent.
function Reporter:finish()
    if self.kind == progress.NULL or self.closed then return end
    local reported = self.events > 0
    local text = reported and summary(self) or nil
    self:erase()
    self:close()
    if text then self:out(text .. "\n") end
end

-- The failing end of the invocation, before its diagnostics. Erasing the
-- region is unconditional: a stale spinner never survives an error.
function Reporter:fail()
    if self.kind == progress.NULL or self.closed then return end
    local reported = self.events > 0
    local text = reported and ("Failed after " ..
        progress.duration(self:elapsed())) or nil
    self:erase()
    self:close()
    if text then self:out(text .. "\n") end
end

return progress
