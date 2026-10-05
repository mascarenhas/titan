local mode,count,host,hooked,stopped=arg[1],assert(tonumber(arg[2])),arg[3],arg[4]=='1',arg[5]=='1'
local probe=assert(package.loadlib(assert(os.getenv('MEASURE_PROBE')),'luaopen_alloc_probe'))()
local async=require 'titan.async'
local bench
if host=='typed' then bench=require 'bench' else bench=dofile(assert(os.getenv('MEASURE_LUA_BENCH'))) end
local scope=arg[6] or 'body'
if scope=='whole' then probe.start(hooked,stopped) end
local task=bench.launch(mode,count,assert(os.getenv('MEASURE_FIXTURE')),function() if scope=='body' then probe.start(hooked,stopped) end end,probe.stop_body)
async.loop()
local status=task:status()
if status:as_string()~='succeeded' then
 local failed,failure=status:has_failed()
 error(failed and failure.traceback or 'benchmark did not succeed')
end
task,status=nil,nil
local result=probe.finish()
assert(result.postgc_ledger_error_bytes==0,'allocator ledger does not match Lua heap')
local function encode(value)
 if type(value)=='number' then return string.format('%.17g',value) end
 if type(value)=='string' then return string.format('%q',value) end
 if type(value)=='boolean' then return value and 'true' or 'false' end
 local keys={};for key in pairs(value) do keys[#keys+1]=key end;table.sort(keys)
 local result={};for i,key in ipairs(keys) do result[i]=encode(key)..':'..encode(value[key]) end
 return '{'..table.concat(result,',')..'}'
end
result.mode,result.iterations,result.host,result.scope=mode,count,host,scope
print(encode(result))
