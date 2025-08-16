# benchmark_working2.ps1
# Bench SWI-Prolog / OCaml (bytecode) / Lua / C++. Results go to *.out.txt; timings printed.

$ErrorActionPreference = "Stop"

# ---- Params ----
$N=30; $Runs=300; $TimeoutSec=3000
$PrologStack="2048M"
$NPrologNaive=[Math]::Min(30,$N)
$NLuaNaive   =[Math]::Min(35,$N)
$NCppNaive   =[Math]::Min(35,$N)


# Direct path, correct expansion
Import-Module "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools" -Arch amd64

function Add-ProcessPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position=0, ValueFromPipeline)]
    [string[]]$Paths,
    [switch]$Prepend,     # put new entries at the front
    [switch]$NoVerify     # skip "directory exists" check
  )
  begin {
    $sep = [IO.Path]::PathSeparator
    $cur = @()
    if ($env:Path) { $cur = $env:Path -split [regex]::Escape($sep) | Where-Object { $_ } }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $cur) { [void]$seen.Add($e.Trim()) }

    $add = @()
  }
  process {
    foreach ($p in $Paths) {
      if ([string]::IsNullOrWhiteSpace($p)) { continue }
      $n = $p.Trim().Trim('"')

      if (-not $NoVerify) {
        $gi = Get-Item -LiteralPath $n -ErrorAction SilentlyContinue
        if (-not $gi -or -not $gi.PSIsContainer) { continue }
        $n = $gi.FullName
      } else {
        try { $n = [IO.Path]::GetFullPath($n) } catch { }
      }
      $n = $n.TrimEnd('\','/')

      if (-not $seen.Contains($n)) {
        $add += $n
        [void]$seen.Add($n)
      }
    }
  }
  end {
    if ($add.Count -gt 0) {
      $newList = if ($Prepend) { @($add) + $cur } else { $cur + @($add) }
      $env:Path = ($newList -join $sep)   # current process only
    }
    return $env:Path
  }
}


Add-ProcessPath @('C:\Program Files\swipl\bin', "$env:localappdata\opam\5.2.0-msvc\bin") -Prepend


# ---- Setup ----
$WorkDir = Join-Path $PWD "fib_bench"
$LogDir  = Join-Path $WorkDir "logs"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null
Set-Location $WorkDir

# ---- Helpers ----
function Have($exe){ Get-Command $exe -ErrorAction SilentlyContinue }
function Find-Exe([string[]]$names){ foreach($n in $names){ $c=Get-Command $n -EA SilentlyContinue; if($c){return $c.Source} } $null }
function Log([string]$msg){ Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) }

function Invoke-TimedProc($Label,[string]$Exe,[string[]]$ArgList,[int]$Nused){
  $tag = ($Label -replace '[:\s]','_').ToLower()
  $out = Join-Path $LogDir "$tag.out.txt"
  $err = Join-Path $LogDir "$tag.err.txt"
  Log "RUN $Label"; Log " EXE: $Exe"; Log " OUT: $out"; Log " ERR: $err"
  $p = Start-Process -FilePath $Exe -ArgumentList $ArgList -NoNewWindow -PassThru `
       -WorkingDirectory $PWD -RedirectStandardOutput $out -RedirectStandardError $err
  if(-not $p.WaitForExit($TimeoutSec*1000)){ try{$p.Kill()}catch{}; throw "Timeout (warm-up): $Label" }
  if($p.ExitCode -ne 0){ throw "Warm-up nonzero exit ($($p.ExitCode)): $Label. See $err" }
  $total=0.0
  for($i=1;$i -le $Runs;$i++){
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgList -NoNewWindow -PassThru `
         -WorkingDirectory $PWD -RedirectStandardOutput $out -RedirectStandardError $err
    if(-not $p.WaitForExit($TimeoutSec*1000)){ try{$p.Kill()}catch{}; throw "Timeout: $Label (run $i)" }
    $sw.Stop(); if($p.ExitCode -ne 0){ throw "Run $i nonzero exit ($($p.ExitCode)): $Label. See $err" }
    $total += $sw.Elapsed.TotalMilliseconds
  }
  [pscustomobject]@{ Language=$Label.Split(':')[0]; Variant=$Label.Split(':')[1]; N=$Nused; Runs=$Runs; AvgMs=[math]::Round($total/$Runs,2) }
}

# Initialize MSVC environment (so cl/link can find headers/libs)
function Import-VsDevEnv {
  $vsDevCmd = $null
  if (Get-Command vswhere -EA SilentlyContinue){
    $vsDevCmd = & vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                 -find "Common7\Tools\VsDevCmd.bat" | Select-Object -First 1
    if(-not $vsDevCmd){
      $vsDevCmd = & vswhere -latest -products * -find "VC\Auxiliary\Build\vcvars64.bat" | Select-Object -First 1
    }
  }
  if(-not $vsDevCmd){ return $false }
  Log "Initializing MSVC env via: $vsDevCmd"
  $envDump = & cmd /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
  foreach($line in $envDump){ if($line -match '^(.*?)=(.*)$'){ $k=$matches[1]; $v=$matches[2]; Set-Item -Path "Env:$k" -Value $v -EA SilentlyContinue } }
  return $true
}

# ---- Prolog sources ----
@'
fib(0,0). fib(1,1).
fib(N,F) :- N>1, N1 is N-1, N2 is N-2, fib(N1,F1), fib(N2,F2), F is F1+F2.
run(N) :- fib(N,F), writeln(F).
'@ | Set-Content fib_naive.pl -Encoding UTF8
@'
fib(N,F) :- N>=0, fib_acc(N,0,1,F).
fib_acc(0,A,_,A).
fib_acc(N,A,B,F) :- N>0, N1 is N-1, S is A+B, fib_acc(N1,B,S,F).
run(N) :- fib(N,F), writeln(F).
'@ | Set-Content fib_tail.pl -Encoding UTF8
@'
fib(N,F) :- N>=0, fib_pair(N,F,_).
fib_pair(0,0,1).
fib_pair(N,FN,FN1) :-
  N>0, K is N // 2, fib_pair(K,A,B),
  C is A*(2*B - A), D is A*A + B*B,
  ( 0 is N mod 2 -> FN=C, FN1=D ; FN=D, FN1=C+D ).
run(N) :- fib(N,F), writeln(F).
'@ | Set-Content fib_fast.pl -Encoding UTF8

# ---- OCaml sources ----
@'
let rec fib = function 0->0 | 1->1 | n when n>1 -> fib(n-1)+fib(n-2) | _->invalid_arg "fib"
let () = Printf.printf "%d\n%!" (fib (int_of_string Sys.argv.(1)))
'@ | Set-Content fib_naive.ml -Encoding UTF8
@'
let fib n = if n<0 then invalid_arg "fib" else
  let rec go i a b = if i=n then a else go (i+1) b (a+b) in go 0 0 1
let () = Printf.printf "%d\n%!" (fib (int_of_string Sys.argv.(1)))
'@ | Set-Content fib_tail.ml -Encoding UTF8
@'
let fib n =
  if n<0 then invalid_arg "fib";
  let rec pair k =
    if k=0 then 0,1 else
    let a,b = pair (k lsr 1) in
    let c = a * (2*b - a) in
    let d = a * a + b * b in
    if k land 1 = 0 then c,d else d,c+d
  in fst (pair n)
let () = Printf.printf "%d\n%!" (fib (int_of_string Sys.argv.(1)))
'@ | Set-Content fib_fast.ml -Encoding UTF8

# ---- Lua sources ----
@'
-- fib_naive.lua
local function fib(n)
  if n < 0 then error("neg") end
  if n < 2 then return n end
  return fib(n-1) + fib(n-2)
end
local n = tonumber(arg[1]); print(fib(n))
'@ | Set-Content fib_naive.lua -Encoding UTF8
@'
-- fib_tail.lua
local function fib(n)
  if n < 0 then error("neg") end
  local a,b = 0,1
  for _=1,n do a,b = b,a+b end
  return a
end
local n = tonumber(arg[1]); print(fib(n))
'@ | Set-Content fib_tail.lua -Encoding UTF8
@'
-- fib_fast.lua (fast doubling)
local function pair(n)
  if n == 0 then return 0,1 end
  local a,b = pair(math.floor(n/2))
  local c = a * (2*b - a)
  local d = a*a + b*b
  if n % 2 == 0 then return c,d else return d, c + d end
end
local n = tonumber(arg[1]); local f,_ = pair(n); print(f)
'@ | Set-Content fib_fast.lua -Encoding UTF8

# ---- C++ sources ----
@'
/* fib_naive.cpp */
#include <iostream>
#include <stdexcept>
#include <cstdint>
#include <string>

long long fib(long long n){
  if(n<0) throw std::runtime_error("neg");
  if(n<2) return n;
  return fib(n-1)+fib(n-2);
}
int main(int argc,char**argv){
  long long n = std::stoll(argv[1]);
  std::cout << fib(n) << "\n";
}
'@ | Set-Content fib_naive.cpp -Encoding UTF8
@'
/* fib_tail.cpp */
#include <iostream>
#include <stdexcept>
#include <cstdint>
#include <string>
long long fib(long long n){
  if(n<0) throw std::runtime_error("neg");
  long long a=0,b=1;
  for(long long i=0;i<n;i++){ long long t=a+b; a=b; b=t; }
  return a;
}
int main(int argc,char**argv){
  long long n = std::stoll(argv[1]);
  std::cout << fib(n) << "\n";
}
'@ | Set-Content fib_tail.cpp -Encoding UTF8
@'
/* fib_fast.cpp (fast doubling) */
#include <iostream>
#include <utility>
#include <cstdint>
#include <string>
std::pair<long long,long long> pf(long long n){
  if(n==0) return {0,1};
  auto [a,b] = pf(n/2);
  long long c = a*(2*b - a);
  long long d = a*a + b*b;
  if(n%2==0) return {c,d}; else return {d,c+d};
}
int main(int argc,char**argv){
  long long n = std::stoll(argv[1]);
  std::cout << pf(n).first << "\n";
}
'@ | Set-Content fib_fast.cpp -Encoding UTF8

# ---- Detect toolchains ----
$swiplCmd   = Have "swipl"; $swipl = if($swiplCmd){ $swiplCmd.Source } else { $null }
$ocamlcCmd  = Have "ocamlc"; $ocamlc= if($ocamlcCmd){ $ocamlcCmd.Source } else { $null }
$luaPath    = Find-Exe @("lua","lua54","lua53","lua52","lua51","lua5.4","lua5.3","lua5.2","lua5.1")
$luajitCmd  = Have "luajit"
if(-not $luaPath -and $luajitCmd){ $luaPath = $luajitCmd.Source; $LuaExtra=@("-joff") } else { $LuaExtra=@() }
$haveLua    = [bool]$luaPath
$clPath     = Find-Exe @("cl.exe")
$gxxPath    = Find-Exe @("g++.exe","clang++.exe","g++","clang++")
$haveMSVC   = [bool]$clPath
$haveGxx    = [bool]$gxxPath

Log "Found ocamlc:    $([bool]$ocamlc)"
Log "Found lua:       $haveLua ($luaPath)"
Log "Found cl:        $haveMSVC ($clPath)"
Log "Found g++/clang: $haveGxx ($gxxPath)"

# ---- Build OCaml (bytecode) ----
Remove-Item -EA SilentlyContinue .\fib_*ml*.exe
Start-Sleep -Milliseconds 150
$BuiltOcamlBc = $false
if($ocamlc){
  Log "Building OCaml (bytecode)…"
  & $ocamlc -o fib_naive_ml.bc.exe fib_naive.ml
  & $ocamlc -o fib_tail_ml.bc.exe  fib_tail.ml
  & $ocamlc -o fib_fast_ml.bc.exe  fib_fast.ml
  $BuiltOcamlBc = Test-Path .\fib_naive_ml.bc.exe
}else{
  Log "ocamlc not found. Skipping OCaml."
}

# ---- Build C++ ----
Remove-Item -EA SilentlyContinue .\fib_naive_cpp.exe,.\fib_tail_cpp.exe,.\fib_fast_cpp.exe
Start-Sleep -Milliseconds 150
$BuiltCpp=$false
if($haveMSVC){
  if(-not (Import-VsDevEnv)){ Log "MSVC env init not found; build may fail." }
  Log "Building C++ with MSVC…"
  $clOutN = Join-Path $LogDir "cl_naive.out.txt"; $clErrN = Join-Path $LogDir "cl_naive.err.txt"
  & "$clPath" /nologo /O2 /EHsc /std:c++17 fib_naive.cpp /Fe:fib_naive_cpp.exe  1> $clOutN 2> $clErrN; if($LASTEXITCODE){ throw "cl failed: fib_naive.cpp. See $clErrN" }
  $clOutT = Join-Path $LogDir "cl_tail.out.txt";  $clErrT = Join-Path $LogDir "cl_tail.err.txt"
  & "$clPath" /nologo /O2 /EHsc /std:c++17 fib_tail.cpp  /Fe:fib_tail_cpp.exe   1> $clOutT 2> $clErrT; if($LASTEXITCODE){ throw "cl failed: fib_tail.cpp. See $clErrT" }
  $clOutF = Join-Path $LogDir "cl_fast.out.txt";  $clErrF = Join-Path $LogDir "cl_fast.err.txt"
  & "$clPath" /nologo /O2 /EHsc /std:c++17 fib_fast.cpp  /Fe:fib_fast_cpp.exe   1> $clOutF 2> $clErrF; if($LASTEXITCODE){ throw "cl failed: fib_fast.cpp. See $clErrF" }
  $BuiltCpp = Test-Path .\fib_fast_cpp.exe
}elseif($haveGxx){
  Log "Building C++ with $([IO.Path]::GetFileName($gxxPath))…"
  & $gxxPath -O3 -std=c++17 fib_naive.cpp -o fib_naive_cpp.exe
  & $gxxPath -O3 -std=c++17 fib_tail.cpp  -o fib_tail_cpp.exe
  & $gxxPath -O3 -std=c++17 fib_fast.cpp  -o fib_fast_cpp.exe
  $BuiltCpp = Test-Path .\fib_fast_cpp.exe
}else{
  Log "C++ compiler not found. Skipping C++."
}

# ---- Benchmark ----
$results=@()

if($swipl){
  Log "Benchmarking SWI-Prolog…"
  $plNaive = ((Resolve-Path .\fib_naive.pl).Path) -replace '\\','/'
  $plTail  = ((Resolve-Path .\fib_tail.pl ).Path) -replace '\\','/'
  $plFast  = ((Resolve-Path .\fib_fast.pl ).Path) -replace '\\','/'
  $results += Invoke-TimedProc "Prolog:Naive" $swipl @("--stack_limit=$PrologStack","-q","--on-error=halt","-f","none","-s",$plNaive,"-g",("run({0})" -f $NPrologNaive),"-t","halt") $NPrologNaive
  $results += Invoke-TimedProc "Prolog:Tail"  $swipl @("--stack_limit=$PrologStack","-q","--on-error=halt","-f","none","-s",$plTail, "-g",("run({0})" -f $N),"-t","halt") $N
  $results += Invoke-TimedProc "Prolog:Fast"  $swipl @("--stack_limit=$PrologStack","-q","--on-error=halt","-f","none","-s",$plFast, "-g",("run({0})" -f $N),"-t","halt") $N
}else{
  Log "swipl not found. Skipping Prolog."
}

if($BuiltOcamlBc){
  Log "Benchmarking OCaml (bytecode)…"
  $results += Invoke-TimedProc "OCamlbc:Naive" (Resolve-Path .\fib_naive_ml.bc.exe).Path @("$N") $N
  $results += Invoke-TimedProc "OCamlbc:Tail"  (Resolve-Path .\fib_tail_ml.bc.exe ).Path @("$N") $N
  $results += Invoke-TimedProc "OCamlbc:Fast"  (Resolve-Path .\fib_fast_ml.bc.exe ).Path @("$N") $N
}

if($haveLua){
  Log "Benchmarking Lua…"
  $results += Invoke-TimedProc "Lua:Naive" $luaPath ($LuaExtra + @((Resolve-Path .\fib_naive.lua).Path,"$NLuaNaive")) $NLuaNaive
  $results += Invoke-TimedProc "Lua:Tail"  $luaPath ($LuaExtra + @((Resolve-Path .\fib_tail.lua ).Path,"$N"))        $N
  $results += Invoke-TimedProc "Lua:Fast"  $luaPath ($LuaExtra + @((Resolve-Path .\fib_fast.lua ).Path,"$N"))        $N
}else{
  Log "lua not found. Skipping Lua."
}

if($BuiltCpp){
  Log "Benchmarking C++…"
  $results += Invoke-TimedProc "C++:Naive" (Resolve-Path .\fib_naive_cpp.exe).Path @("$NCppNaive") $NCppNaive
  $results += Invoke-TimedProc "C++:Tail"  (Resolve-Path .\fib_tail_cpp.exe ).Path @("$N")         $N
  $results += Invoke-TimedProc "C++:Fast"  (Resolve-Path .\fib_fast_cpp.exe ).Path @("$N")         $N
}

# ---- Report ----
$swiplVer = if($swipl){ (& $swipl --version) -replace '\r|\n',' ' } else { "not found" }
$ocamlVer = if($ocamlc){ (& $ocamlc -vnum) } else { "not found" }
$luaVer   = if($haveLua){ try { (& $luaPath -v @($LuaExtra)) 2>&1 | Select-Object -First 1 } catch { "unknown" } } else { "not found" }
$cxxVer   = if($haveMSVC){ "MSVC cl" } elseif($haveGxx){ [IO.Path]::GetFileName($gxxPath) } else { "not found" }
Log "OCaml (bc): $ocamlVer"; Log "Lua: $luaVer"; Log "C++: $cxxVer"

if($results.Count -gt 0){
  $results | Sort-Object AvgMs | Format-Table Language,Variant,N,AvgMs,Runs -AutoSize
  $results | Export-Csv -NoTypeInformation -Path (Join-Path $PWD "fib_timings.csv") -Encoding UTF8
  Log "Saved: $(Join-Path $PWD "fib_timings.csv")"
}else{
  Log "Nothing to run."
}
Log "DONE"
