local async = require 'titan.async'
local timer = require 'titan.timer'
local fs = require 'titan.fs'
local titan_os = require 'titan.os'
local M = {}
local function success_nil(resolve) resolve(nil) end
local function error_nil(_,reject) reject(nil) end
local function success_false(resolve) resolve(false) end
local function error_false(_,reject) reject(false) end
local function stop_source() end
local function close_source(drain) drain() end
local function actions() return async.SubscriptionActions(stop_source,close_source) end
function M.launch(mode,count,path,start,stop)
 return async.run(function()
  if mode=='os_write' then
   local process=titan_os.spawn('/bin/sh',require('bench').child_args())
   start()
   for i=1,count do process.stdin:write('abcdefghijklmnopqrstuvwxyz012345') end
   stop()
   process.stdin:close()
   local result=process:wait()
   assert(result.code==0 and result.signal_number==0)
   process.stdout:close();process.stderr:close()
  elseif mode=='fs_write' then
   local file=fs.open('/dev/null','w')
   start()
   for i=1,count do assert(file:write('abcdefghijklmnopqrstuvwxyz012345')==32) end
   stop();file:close()
  elseif mode=='subscription_next' then
   local publish
   local subscription=async.BufferedSubscription(function(send) publish=send;return actions() end)
   start()
   for i=1,count do assert(publish(false)); subscription:next() end
   stop();subscription:close()
  else
   start()
   for i=1,count do
    if mode=='control' then
    elseif mode=='yield' then async.yield()
    elseif mode=='yield_observed' then
     local old=async.running():status();async.yield();local current=async.running():status()
     assert(old~=current and current:as_string()=='running')
    elseif mode=='inline_success_nil' then async.await(success_nil)
    elseif mode=='inline_error_nil' then async.await(error_nil)
    elseif mode=='inline_success_false' then async.await(success_false)
    elseif mode=='inline_error_false' then async.await(error_false)
    elseif mode=='cleanup_inline' then async.await_cleanup(success_nil)
    elseif mode=='timer_sleep' then timer.sleep(0)
    elseif mode=='fs_stat' then assert(fs.stat(path)~=nil)
    elseif mode=='fs_reject' then local ok=pcall(fs.open,path..'.missing','r');assert(not ok)
    elseif mode=='cleanup_close' then local file=fs.open('/dev/null','r');file:close()
    elseif mode=='subscription_setup' then local subscription=async.BufferedSubscription(actions);subscription:close()
    elseif mode=='cancel_queued' then
     local child=async.run(function() error('cancelled queued child ran') end);child:cancel()
     assert(async.join(child):as_string()=='cancelled')
    elseif mode=='cancel_running' then
     local entered,cleaned=false,false
     local token=async.ResumeToken('measurement')
     local child=async.run(function()
      entered=true
      local ok=pcall(async.suspend,token)
      async.await_cleanup(success_nil);cleaned=true
      if ok then error('cancelled suspended child continued') end
     end)
     while not entered do async.yield() end
     child:cancel();assert(async.join(child):as_string()=='cancelled' and cleaned)
    else error('unknown benchmark mode') end
   end
   stop()
  end
 end)
end
return M
