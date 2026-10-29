local h = require "spec.support.helpers"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local module = "documentation_reflection"
local provider = "./" .. module .. (platform.windows and ".dll" or ".so")

describe("documentation metadata at runtime", function()
    after_each(function()
        for _, suffix in ipairs({".c", ".o", ".so", ".dll", ".dll.def", ".a", ".ffi.h", ".titan.h"}) do
            os.remove(module .. suffix)
        end
        if not platform.windows then
            os.execute("rm -rf " .. module .. ".so.dSYM")
        end
    end)
    it("hydrates documented records, unions, interfaces and callable signatures", function()
        local ok, err = h.build_so_chain({{name=module, src=[[
--- Reflection fixture.
-- @module documentation_reflection
local reflect = import "reflect"
--- A documented box.
-- @field item Stored count.
record Box const item:integer end
--- Read the count.
function Box:get():integer return self.item end
--- A documented view.
interface View
  --- Captured count.
  item:integer
  --- Read the count.
  function get():integer
end
--- A documented choice.
union Choice
  --- A populated choice.
  Some(item:integer)
end
--- Inspect all nominal and callable tags.
function check():integer
  local box=Box(42)
  local result=0
  case reflect.inspect(box)
  when is_record(r) then result=result+(r:get(1) as integer)
  else raise "record tag did not hydrate"
  end
  case reflect.inspect(Choice.Some(42))
  when is_union(u) then result=result+(u:get(1) as integer)
  else raise "union tag did not hydrate"
  end
  local view:View=box
  case reflect.inspect(view)
  when is_interface(i) then result=result+(i:get(1) as integer)
  else raise "interface tag did not hydrate"
  end
  case reflect.inspect(box:get)
  when is_titan_function{signature=type} then
    result=result+#signature.return_descriptors
  else raise "callable tag did not hydrate"
  end
  return result
end
]]}})
        assert.truthy(ok, err)
        local ran, output=h.call(module, [[assert(documentation_reflection.check()==127)]])
        assert.truthy(ran, output)
        local metadata=assert(require("titan")._loadlib(provider,module.."_types"))()
        assert.truthy(metadata:find("Documented(",1,true),"language-server metadata lost documentation")
        assert.truthy(driver.decode_module_interface(metadata,module))
    end)
end)
