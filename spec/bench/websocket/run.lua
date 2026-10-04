local config = dofile(assert(arg[1]))
local async = require 'titan.async'
local bench = require 'bench'
local function load_probe(path, entry) return assert(package.loadlib(path, entry))() end
local probe = load_probe(assert(os.getenv('MEASURE_PROBE')), 'luaopen_alloc_probe')
local latency = load_probe(assert(os.getenv('MEASURE_LATENCY_PROBE')), 'luaopen_latency_probe')
local payload = string.rep('x', config.size)
local weak = setmetatable({}, {__mode='v'})
local held
local boundaries = {ready=0, body_done=0, closed=0}
local function ready(endpoint)
  boundaries.ready = boundaries.ready + 1
  weak[1] = endpoint
  if config.retain_endpoint then held = endpoint end
  if config.transport ~= 'control' then
    local file = assert(io.open(config.go_marker, 'w'))
    assert(file:write('go\n')); assert(file:close())
  end
  if config.phase == 'steady' or config.phase == 'sessions' then probe.start(config.instrumented, config.gc_stopped) end
  if config.phase == 'setup' then probe.stop_body() end
end
local function body_done()
  boundaries.body_done = boundaries.body_done + 1
  if config.phase == 'steady' or config.phase == 'sessions' then probe.stop_body() end
  if config.phase == 'teardown' then probe.start(config.instrumented, config.gc_stopped) end
end
local function closed()
  boundaries.closed = boundaries.closed + 1
  if config.phase == 'teardown' then probe.stop_body() end
end
if config.phase == 'setup' then probe.start(config.instrumented, config.gc_stopped) end
local task = bench.launch(config.transport, config.role, config.operation, config.count,
  config.port, payload, config.kind, config.cleanup, config.ca, config.certificate,
  config.key, config.preload_marker, config.tasks or 1, ready, body_done, closed,
  latency.start, latency.sample)
async.loop()
local status = task:status()
if status:as_string() ~= 'succeeded' then
  local failed, failure = status:has_failed()
  error(failed and failure.traceback or 'benchmark did not succeed')
end
for name, count in pairs(boundaries) do assert(count == 1, 'incorrect boundary: '..name) end
task, status = nil, nil
local fairness
if config.operation == 'fairness' then fairness = latency.finish() end
local result = probe.finish()
assert(result.postgc_ledger_error_bytes == 0, 'allocator ledger differs from Lua heap')
result.closed_endpoint_held_through_postgc = config.retain_endpoint
result.endpoint_reachable_after_postgc = weak[1] ~= nil
held = nil
collectgarbage('collect'); collectgarbage('collect')
result.endpoint_collected_after_release = weak[1] == nil
if fairness then result.fairness = fairness end
local function encode(item)
  if type(item) == 'number' then return string.format('%.17g', item) end
  if type(item) == 'boolean' then return item and 'true' or 'false' end
  if type(item) == 'string' then return string.format('%q', item) end
  local keys = {}; for key in pairs(item) do keys[#keys+1] = key end; table.sort(keys)
  local out = {}; for index, key in ipairs(keys) do out[index] = encode(key)..':'..encode(item[key]) end
  return '{'..table.concat(out, ',')..'}'
end
print(encode(result))
