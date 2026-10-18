local cli = assert(table.remove(arg, 1))
local allowed = assert(table.remove(arg, 1))
local requested_cflags = assert(table.remove(arg, 1), "missing complete generated-C flag policy")
local line_directives = assert(table.remove(arg, 1), "missing source-line policy")
local build_profile = assert(table.remove(arg, 1), "missing build profile")
assert(line_directives == "0" or line_directives == "1", "invalid source-line policy")
assert(build_profile == "production" or build_profile == "validation", "invalid build profile")
local provider_root = allowed:match("^provider:(.*)$")
arg[0] = cli
local driver = require "titan-compiler.driver"
assert(driver.TITAN_ABI_VERSION == "2",
       "measurement requires current generated ABI 2: " .. tostring(driver.TITAN_ABI_VERSION))
assert(driver.TITAN_VERSION == "0.6.0", "package version changed")
assert(driver.TITAN_LIBRARY_VERSION == "0.6", "SDK namespace changed")
assert(driver.LANGUAGE_SERVER_API_VERSION == 1, "language-server API changed")
assert(driver.BUILD_PROFILE == build_profile, "compiler build profile differs from receipt")
driver.EMIT_LINE_DIRECTIVES = line_directives == "1"
local expected_cflags = assert(driver.split_shell_words(requested_cflags))
assert(#expected_cflags > 0, "complete generated-C flags must not be empty")
local expected_cppflags = {}
for index, flag in ipairs(assert(driver.EXTRA_CPPFLAGS)) do expected_cppflags[index] = flag end
local policy_checks = 0
local function check_flags(actual, expected, label)
  assert(#actual == #expected, label .. " argument count differs from attested policy")
  for index, flag in ipairs(expected) do
    assert(actual[index] == flag, label .. " differs at argv " .. tostring(index) ..
      ": expected " .. tostring(flag) .. ", got " .. tostring(actual[index]))
  end
  assert(driver.BUILD_PROFILE == build_profile, "compiler build profile changed")
  assert(driver.EMIT_LINE_DIRECTIVES == (line_directives == "1"), "source-line policy changed")
  policy_checks = policy_checks + 1
end
local function expected_compile_flags()
  local flags = {}
  for _, flag in ipairs(expected_cppflags) do flags[#flags + 1] = flag end
  for _, flag in ipairs(expected_cflags) do flags[#flags + 1] = flag end
  return flags
end
-- Preserve the SDK's own defaults and replay its attested EXTRA_CFLAGS. Never
-- replace an inferred default with a partial "-O3" policy or silently drop LTO.
local descriptor = assert(driver.toolchain_descriptor)
driver.toolchain_descriptor = function(context)
  local result, err = descriptor(context)
  if not result then return nil, err end
  check_flags(result.compile_flags, expected_compile_flags(), "native toolchain flags")
  return result
end
local compile_prefix = assert(driver.generated_compile_prefix)
driver.generated_compile_prefix = function()
  local result, err = compile_prefix()
  if not result then return nil, err end
  local expected = assert(driver.split_shell_words(driver.CC))
  for _, flag in ipairs(expected_compile_flags()) do expected[#expected + 1] = flag end
  for _, directory in ipairs(driver.foreign_include_dirs()) do
    expected[#expected + 1] = "-I"
    expected[#expected + 1] = directory
  end
  check_flags(result, expected, "generated-C compile prefix")
  return result
end
local parser = require "titan-compiler.parser"
local parse = parser.parse
local count = 0
parser.parse = function(filename, input)
  if provider_root then
    assert(filename:sub(1, #provider_root + 1) == provider_root .. "/",
           "unexpected provider source fallback: " .. tostring(filename))
  else
    assert(filename == allowed, "unexpected source fallback: " .. tostring(filename))
  end
  count = count + 1
  io.stdout:write("MEASUREMENT_SOURCE_PARSE:", filename, "\n")
  return parse(filename, input)
end
dofile(cli)
assert(provider_root and count >= 26 or not provider_root and count == 1,
       "measurement must parse the full private provider or exactly one consumer")
assert(policy_checks > 0, "compiler did not expose its actual native flag policy")
io.stdout:write("MEASUREMENT_SOURCE_POLICY: profile=", build_profile,
  " emit_line_directives=", line_directives, " prefix_checks=", tostring(policy_checks), "\n")
if provider_root then
  io.stdout:write("PRIVATE_PROVIDER_SOURCES: ABI=", tostring(driver.TITAN_ABI_VERSION),
    " parsed_sources=", tostring(count), "\n")
else
  io.stdout:write("SOURCE_FREE_IMPORTS: ABI=", tostring(driver.TITAN_ABI_VERSION),
    " SDK=0.6 LSP=1 consumer_sources=1\n")
end
