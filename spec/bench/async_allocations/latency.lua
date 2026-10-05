local tasks,iterations=assert(tonumber(arg[1])),assert(tonumber(arg[2]))
local probe=assert(package.loadlib(assert(os.getenv('MEASURE_LATENCY_PROBE')),'luaopen_latency_probe'))()
local async=require 'titan.async'
local latency=require 'latency'
probe.start(tasks,iterations)
local task=latency.launch(tasks,iterations,probe.sample)
async.loop()
assert(task:status():as_string()=='succeeded')
local result=probe.finish()
assert(result.yield_latency.samples==tasks*iterations)
result.tasks,result.iterations=tasks,iterations
local function encode(value)
 if type(value)=='number' then return string.format('%.17g',value) end
 if type(value)=='string' then return string.format('%q',value) end
 local keys={};for key in pairs(value) do keys[#keys+1]=key end;table.sort(keys)
 local result={};for i,key in ipairs(keys) do result[i]=encode(key)..':'..encode(value[key]) end
 return '{'..table.concat(result,',')..'}'
end
print(encode(result))
