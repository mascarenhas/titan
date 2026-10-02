# Run from ordinary Windows PowerShell after the CLANG64 lua-check target.
# This process-local PATH does not affect the machine or user environment.
param(
    [Parameter(Mandatory = $true)][string]$BuildRoot
)
$ErrorActionPreference = 'Stop'
$checkRoot = Join-Path ([System.IO.Path]::GetFullPath($BuildRoot)) 'lua-check'
$probeRoot = [System.IO.File]::ReadAllText(
    (Join-Path $checkRoot 'native-probe-path.txt'),
    [System.Text.Encoding]::UTF8).TrimEnd([char[]]"`r`n")
$runtime = Join-Path $probeRoot ('runtime ' + [char]0x00fc + ' space')
$provider = Join-Path $probeRoot ('providers ' + [char]0x00e9)
$lua = Join-Path $runtime 'bin\lua.exe'
$script = Join-Path $probeRoot 'probe.lua'
$canary = Join-Path $provider 'canary.dll'
$dependency = Join-Path $runtime 'bin\titan_lua_loader_dependency.dll'
$disabled = $dependency + '.disabled'
if (!(Test-Path -LiteralPath $dependency -PathType Leaf) -or
    (Test-Path -LiteralPath $disabled)) {
    throw 'Expected a completed native lua-check with its original canary files'
}
function Invoke-CheckedLua {
    param([string[]]$LuaArguments)
    & $lua @LuaArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Native Lua check failed with exit code $LASTEXITCODE"
    }
}
$originalPath = $env:PATH
$originalLocation = Get-Location
$moved = $false
try {
    $env:PATH = Join-Path $probeRoot 'path'
    Set-Location -LiteralPath (Join-Path $probeRoot 'cwd')
    Move-Item -LiteralPath $dependency -Destination $disabled
    $moved = $true
    Invoke-CheckedLua -LuaArguments @('-E', $script, $canary, 'reject')
    Move-Item -LiteralPath $disabled -Destination $dependency
    $moved = $false
    Invoke-CheckedLua -LuaArguments @('-E', $script, $canary, 'accept')
    Set-Location -LiteralPath $provider
    Invoke-CheckedLua -LuaArguments @('-E', $script, '.\canary.dll', 'accept')
    Write-Output 'Clean PowerShell Lua relocation and controlled DLL search passed'
}
finally {
    if ($moved) {
        Move-Item -LiteralPath $disabled -Destination $dependency
    }
    $env:PATH = $originalPath
    Set-Location -LiteralPath $originalLocation.Path
}
