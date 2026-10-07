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
$canary = Join-Path $provider 'titan_loader_canary.dll'
$dependency = Join-Path $runtime 'bin\titan_lua_loader_dependency.dll'
$disabled = $dependency + '.disabled'
$dependencyPath = Join-Path $probeRoot 'path'
$pathDependency = Join-Path $dependencyPath 'titan_lua_loader_dependency.dll'
if (!(Test-Path -LiteralPath $dependency -PathType Leaf) -or
    (Test-Path -LiteralPath $disabled) -or
    (Test-Path -LiteralPath $pathDependency)) {
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
$currentDependency = $dependency
try {
    $env:PATH = $dependencyPath
    Set-Location -LiteralPath (Join-Path $probeRoot 'cwd')
    Move-Item -LiteralPath $dependency -Destination $disabled
    $currentDependency = $disabled
    Invoke-CheckedLua -LuaArguments @('-E', $script, $canary, 'reject')
    Move-Item -LiteralPath $disabled -Destination $pathDependency
    $currentDependency = $pathDependency
    Invoke-CheckedLua -LuaArguments @('-E', $script, $canary, 'accept')
    Move-Item -LiteralPath $pathDependency -Destination $dependency
    $currentDependency = $dependency
    Invoke-CheckedLua -LuaArguments @('-E', $script, $canary, 'accept')
    Set-Location -LiteralPath $provider
    Invoke-CheckedLua -LuaArguments @('-E', $script, '.\titan_loader_canary.dll', 'accept')
    Write-Output 'Clean PowerShell Lua relocation and ordinary Windows DLL search passed'
}
finally {
    try {
        if ($currentDependency -ne $dependency) {
            Move-Item -LiteralPath $currentDependency -Destination $dependency
        }
    }
    finally {
        $env:PATH = $originalPath
        Set-Location -LiteralPath $originalLocation.Path
    }
}
