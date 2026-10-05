local config = dofile(assert(arg[1]))
local async = require 'titan.async'
local bench = require 'bench'
local function load_probe(path, entry) return assert(package.loadlib(path, entry))() end
local probe = load_probe(assert(os.getenv('MEASURE_PROBE')), 'luaopen_alloc_probe')
local latency = load_probe(assert(os.getenv('MEASURE_LATENCY_PROBE')), 'luaopen_latency_probe')
local sampling
local function begin_sampling(tasks, iterations)
  latency.start(tasks, iterations)
  sampling = {yield_capacity=tasks*iterations, timer_capacity=1000000,
    yield_intervals_observed=0, timer_intervals_observed=0,
    yield_intervals_recorded=0, timer_intervals_recorded=0,
    yield_intervals_dropped=0, timer_intervals_dropped=0, truncated=false,
    seen={}}
  for owner=0,tasks do sampling.seen[owner] = false end
end
local function bounded_sample(owner)
  assert(sampling and sampling.seen[owner] ~= nil, 'sample owner out of range')
  if not sampling.seen[owner] then
    sampling.seen[owner] = true
    latency.sample(owner)
    return
  end
  if owner == 0 then
    sampling.timer_intervals_observed = sampling.timer_intervals_observed + 1
    if sampling.timer_intervals_recorded == sampling.timer_capacity then
      sampling.timer_intervals_dropped = sampling.timer_intervals_dropped + 1
      sampling.truncated = true
      return
    end
    sampling.timer_intervals_recorded = sampling.timer_intervals_recorded + 1
  else
    sampling.yield_intervals_observed = sampling.yield_intervals_observed + 1
    if sampling.yield_intervals_recorded == sampling.yield_capacity then
      sampling.yield_intervals_dropped = sampling.yield_intervals_dropped + 1
      sampling.truncated = true
      return
    end
    sampling.yield_intervals_recorded = sampling.yield_intervals_recorded + 1
  end
  latency.sample(owner)
end
local payload = string.rep('x', config.size)
local weak = setmetatable({}, {__mode='v'})
local held
local measurement_started = false
local measurement_body_stopped = false
local function start_measurement()
  probe.start(config.instrumented, config.gc_stopped)
  measurement_started = true
end
local function stop_measurement()
  probe.stop_body()
  measurement_body_stopped = true
end
local function finish_measurement()
  if not measurement_started then return end
  if not measurement_body_stopped then stop_measurement() end
  local result = probe.finish()
  measurement_started = false
  return result
end
local boundaries = {ready=0, body_done=0, closed=0}
local listener_generation = 0
local function listening()
  listener_generation = listener_generation + 1
  local file = assert(io.open(config.listen_marker, 'w'))
  assert(file:write('listening:'..listener_generation..'\n'))
  assert(file:close())
end
local function ready(endpoint)
  boundaries.ready = boundaries.ready + 1
  weak[1] = endpoint
  if config.retain_endpoint then held = endpoint end
  if config.transport ~= 'control' then
    local file = assert(io.open(config.go_marker, 'w'))
    assert(file:write('go\n')); assert(file:close())
  end
  if config.phase == 'steady' or config.phase == 'sessions' then start_measurement() end
  if config.phase == 'setup' then stop_measurement() end
end
local function body_done()
  boundaries.body_done = boundaries.body_done + 1
  if config.phase == 'steady' or config.phase == 'sessions' then stop_measurement() end
  if config.phase == 'teardown' then start_measurement() end
end
local function closed()
  boundaries.closed = boundaries.closed + 1
  if config.phase == 'teardown' then stop_measurement() end
end
local task, status, fairness, result
local succeeded, failure = pcall(function()
  if config.phase == 'setup' then start_measurement() end
  task = bench.launch(config.transport, config.role, config.operation, config.count,
    config.port, payload, config.kind, config.cleanup, config.ca, config.certificate,
    config.key, config.preload_marker, config.tasks or 1, ready, body_done, closed,
    begin_sampling, bounded_sample, listening)
  async.loop()
  status = task:status()
  if status:as_string() ~= 'succeeded' then
    local failed, task_failure = status:has_failed()
    error(failed and task_failure.traceback or 'benchmark did not succeed')
  end
  for name, count in pairs(boundaries) do assert(count == 1, 'incorrect boundary: '..name) end
  task, status = nil, nil
  if config.operation == 'fairness' then
    fairness = latency.finish()
    sampling.seen = nil
    fairness.sampling = sampling
  end
  result = assert(finish_measurement(), 'measurement never started')
end)
if not succeeded then
  task, status = nil, nil
  -- Restore the allocator before an error reaches Lua shutdown and unloads
  -- the probe DSO. Failed runs never emit a successful measurement result.
  local cleaned, cleanup_failure = pcall(finish_measurement)
  if not cleaned then error(tostring(failure)..'\nallocator cleanup failed: '..tostring(cleanup_failure), 0) end
  error(failure, 0)
end
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
