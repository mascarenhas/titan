param([Parameter(Mandatory=$true)][string]$BuildRoot)
$ErrorActionPreference='Stop'
$b=(Resolve-Path -LiteralPath $BuildRoot).Path
$r=[IO.File]::ReadAllText("$b\compiler-check-runtime.txt",[Text.Encoding]::UTF8).Trim()
$r=[regex]::Replace($r,'^/([A-Za-z])/','$1:/').Replace('/','\')
function Quote-Crt([string]$s){'"'+[regex]::Replace([regex]::Replace($s,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
$v=@('capture','','space value','quote"value','trailing\',"文😀",'&|<>^%!')
$si=New-Object Diagnostics.ProcessStartInfo
$si.FileName="$r\bin\titanc.exe";$si.WorkingDirectory=$b
$si.Arguments=($v | ForEach-Object {Quote-Crt $_}) -join ' '
$si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
$si.StandardOutputEncoding=[Text.Encoding]::UTF8;$si.StandardErrorEncoding=[Text.Encoding]::UTF8
$si.EnvironmentVariables['PATH']=''
foreach($n in @('LUA_PATH','LUA_PATH_5_5','LUA_CPATH','LUA_CPATH_5_5','LUA_INIT','LUA_INIT_5_5')){$si.EnvironmentVariables.Remove($n)}
$p=[Diagnostics.Process]::Start($si);$out=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit()
if($p.ExitCode -ne 0 -or $err){throw "Native launch failed $($p.ExitCode): $err"}
$expected=for($i=0;$i -lt $v.Length;$i++){($i+1).ToString()+':'+[BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($v[$i])).Replace('-','').ToLowerInvariant()}
if($out.Replace("`r`n","`n").TrimEnd("`n") -cne ($expected -join "`n")){throw 'Native argv bytes mismatch'}
Write-Output 'PASS: direct PowerShell/System.Diagnostics native EXE, empty PATH, relocated non-ACP root, exact UTF-8 empty/quote/backslash/metachar argv and Lua dependencies'
