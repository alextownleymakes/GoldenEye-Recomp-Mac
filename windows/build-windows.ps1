<#
  Build GoldenEye.exe for Windows (x64).

  UNTESTED: this script was written alongside the macOS build and has not been
  run on a Windows PC yet. It mirrors macos/build-macos.sh step for step, but
  expect it may need fixes. Please report what breaks.

    cd C:\path\to\GoldenEye-Recomp
    windows\build-windows.bat                         # game files already in assets\
    windows\build-windows.bat C:\path\to\30BA9271...  # or: the packed XBLA file

  (build-windows.bat just runs this script with PowerShell's execution policy
  bypassed. You can also run: powershell -ExecutionPolicy Bypass -File windows\build-windows.ps1)

  What it does:
    1. Checks the toolchain (Visual Studio 2022 C++ Build Tools, LLVM/clang,
       CMake, Ninja, Git), installing missing pieces with winget.
    2. Downloads ReXGlue SDK and applies the GoldenEye changes from
       macos\rexglue-sdk-goldeneye.patch (shared by both platforms).
    3. Builds and installs the SDK (once; later runs reuse it).
    4. Recompiles YOUR copy of the game (assets\default.xex) into C++.
    5. Builds GoldenEye.exe and puts it, its DLLs and the game files in
       GoldenEye-Windows\ (self-contained; move the folder anywhere).

  Options:
    -Config Release|RelWithDebInfo|Debug   (default Release)
    -SdkDir <path>    where to keep the SDK checkout/build
                      (default %LOCALAPPDATA%\GoldenEye-Recomp\rexglue-sdk; kept
                      short because Windows has trouble with very long paths)
    -Clean            wipe the previous game build first
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string] $Package = "",
  [ValidateSet("Release", "RelWithDebInfo", "Debug")] [string] $Config = "Release",
  [string] $SdkDir = "",
  [switch] $Clean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

# ReXGlue SDK revision the GoldenEye patch was ported to (main, "Release v0.10.1").
$SdkRepo = "https://github.com/rexglue/rexglue-sdk.git"
$SdkCommit = "546a082a4356173635f6c40510a41ff53e518b5a"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PatchFile = Join-Path $Root "macos\rexglue-sdk-goldeneye.patch"
if (-not $SdkDir) { $SdkDir = Join-Path $env:LOCALAPPDATA "GoldenEye-Recomp\rexglue-sdk" }

function Bold([string]$m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor White }
function Note([string]$m) { Write-Host "    $m" }
function Die([string]$m) { Write-Host ""; Write-Host "Error: $m" -ForegroundColor Red; exit 1 }
# Run a native command and stop on a non-zero exit code. (A plain function, so
# arguments like "-C" or "-j" are passed through untouched.)
function Run {
  $exe = $args[0]
  $rest = @()
  if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
  & $exe @rest
  if ($LASTEXITCODE -ne 0) { Die "Command failed ($LASTEXITCODE): $exe $($rest -join ' ')" }
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
              [Environment]::GetEnvironmentVariable("Path", "User")
  $llvm = Join-Path $env:ProgramFiles "LLVM\bin"
  if ((Test-Path $llvm) -and ($env:Path -notlike "*$llvm*")) { $env:Path = "$llvm;$env:Path" }
}
function Has([string]$cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

if ($env:OS -ne "Windows_NT") { Die "This script is for Windows." }
if (-not [Environment]::Is64BitOperatingSystem) { Die "A 64-bit Windows is required." }

$CfgLower = $Config.ToLower()
$SdkPreset = "win-amd64"
$SdkBuild = Join-Path $SdkDir "out\build\$SdkPreset"
$SdkInstall = Join-Path $SdkDir "out\install\$SdkPreset"
$GamePreset = "win-amd64-$CfgLower"
$GameBuild = Join-Path $Root "out\build\$GamePreset"
$Jobs = [Environment]::ProcessorCount

# --- 1. Toolchain ------------------------------------------------------------
Bold "Checking build tools"
Refresh-Path

# Visual Studio 2022 C++ build tools (MSVC standard library + Windows SDK).
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vswhere) {
  $vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vsPath) {
  if (Has "winget") {
    Note "Installing Visual Studio 2022 Build Tools (C++) with winget. This takes a while..."
    & winget install -e --id Microsoft.VisualStudio.2022.BuildTools --accept-package-agreements `
      --accept-source-agreements --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    if (Test-Path $vswhere) {
      $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
  }
  if (-not $vsPath) {
    Die "Visual Studio 2022 C++ build tools not found. Install 'Build Tools for Visual Studio 2022'
       with the 'Desktop development with C++' workload: https://visualstudio.microsoft.com/downloads/"
  }
}
Note "Visual Studio: $vsPath"

# Load the x64 developer environment (INCLUDE/LIB, rc.exe, mt.exe, link.exe) into
# this session so clang and CMake find the Windows SDK reliably.
$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { Die "Missing $vcvars (reinstall the C++ workload)." }
cmd /c "`"$vcvars`" >nul && set" | ForEach-Object {
  if ($_ -match "^([^=]+)=(.*)$") {
    try { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process") } catch { }
  }
}
# Prefer the standalone LLVM install over any clang bundled with Visual Studio.
$llvmBin = Join-Path $env:ProgramFiles "LLVM\bin"
if ((Test-Path $llvmBin) -and ($env:Path -notlike "$llvmBin*")) { $env:Path = "$llvmBin;$env:Path" }

$wingetIds = @{ clang = "LLVM.LLVM"; cmake = "Kitware.CMake"; ninja = "Ninja-build.Ninja"; git = "Git.Git" }
$missing = @($wingetIds.Keys | Where-Object { -not (Has $_) })
if ($missing.Count -gt 0) {
  if (-not (Has "winget")) {
    Die "Missing: $($missing -join ', '). Install them (LLVM, CMake, Ninja, Git) and re-run."
  }
  foreach ($m in $missing) {
    Note "Installing $m with winget ($($wingetIds[$m]))"
    & winget install -e --id $wingetIds[$m] --accept-package-agreements --accept-source-agreements
  }
  $vcPath = $env:Path
  Refresh-Path
  $env:Path = "$env:Path;$vcPath"
  if ((Test-Path $llvmBin) -and ($env:Path -notlike "$llvmBin*")) { $env:Path = "$llvmBin;$env:Path" }
  $still = @($wingetIds.Keys | Where-Object { -not (Has $_) })
  if ($still.Count -gt 0) {
    Die "Still missing after install: $($still -join ', '). Open a new terminal and re-run."
  }
}

$clangLine = (& clang --version | Select-Object -First 1)
Note "Compiler: $clangLine"
if ($clangLine -match "clang version (\d+)") {
  if ([int]$Matches[1] -lt 19) { Die "Need LLVM/clang 19 or newer for C++23 (winget upgrade LLVM.LLVM)." }
} else { Die "Could not read the clang version." }

$cmakeVer = ((& cmake --version | Select-Object -First 1) -split " ")[2]
Note "CMake $cmakeVer, Ninja $(& ninja --version)"
if ([version]($cmakeVer -replace "-.*$", "") -lt [version]"3.25") {
  Die "CMake 3.25+ required (found $cmakeVer). Run: winget upgrade Kitware.CMake"
}

$drive = (Get-Item $Root).PSDrive
$freeGb = [math]::Floor($drive.Free / 1GB)
Note "Free disk space on $($drive.Name): $freeGb GB"
if ($freeGb -lt 8) {
  Write-Host ""
  Write-Host "    Warning: the SDK + recompiled game need roughly 4-6 GB while building." -ForegroundColor Yellow
  $ans = Read-Host "    You have $freeGb GB free. Continue anyway? [y/N]"
  if ($ans -notmatch "^[Yy]$") { exit 1 }
}

# --- Game files ----------------------------------------------------------------
Bold "Checking game files"
function Test-Stfs([string]$path) {  # Xbox 360 package: starts with "LIVE", "PIRS" or "CON "
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  $fs = [IO.File]::OpenRead($path)
  try {
    $buf = New-Object byte[] 4
    if ($fs.Read($buf, 0, 4) -ne 4) { return $false }
  } finally { $fs.Dispose() }
  $magic = [Text.Encoding]::ASCII.GetString($buf)
  return ($magic -eq "LIVE" -or $magic -eq "PIRS" -or $magic -eq "CON ")
}
$Assets = Join-Path $Root "assets"
$PackagePath = ""
if (Test-Path (Join-Path $Assets "default.xex")) {
  Note "Found assets\default.xex"
} elseif ($Package) {
  if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) { Die "File not found: $Package" }
  if (-not (Test-Stfs $Package)) { Die "$Package is not an Xbox 360 package (LIVE/PIRS/CON)." }
  $PackagePath = (Resolve-Path -LiteralPath $Package).Path
  Note "Will unpack $PackagePath into assets\"
} else {
  New-Item -ItemType Directory -Force -Path $Assets | Out-Null
  # Look anywhere under assets\ (e.g. the whole download folder copied in).
  $found = Get-ChildItem -LiteralPath $Assets -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 1MB -and (Test-Stfs $_.FullName) } | Select-Object -First 1
  if (-not $found) {
    Die "No game files found.
       Copy your GoldenEye XBLA package (the extensionless file) or the
       unpacked game files (default.xex + data) into: $Assets"
  }
  $PackagePath = $found.FullName
  Note "Will unpack $($found.Name) into assets\"
}

# --- 2. SDK checkout + GoldenEye patch -------------------------------------------
Bold "Getting ReXGlue SDK ($SdkCommit)"
# Keep LF line endings (the patch is LF) and allow long paths in submodules.
$gitCfg = @("-c", "core.autocrlf=false", "-c", "core.longpaths=true")
if (-not (Test-Path (Join-Path $SdkDir ".git"))) {
  New-Item -ItemType Directory -Force -Path $SdkDir | Out-Null
  Run git @gitCfg -C $SdkDir init -q
  Run git -C $SdkDir config core.autocrlf false
  Run git -C $SdkDir config core.longpaths true
  Run git -C $SdkDir remote add origin $SdkRepo
  Run git @gitCfg -C $SdkDir fetch --depth 1 origin $SdkCommit
  Run git @gitCfg -C $SdkDir checkout -q FETCH_HEAD
}
Note "Fetching SDK submodules (first run downloads a few hundred MB)..."
Run git @gitCfg -C $SdkDir submodule update --init --depth 1 --jobs 8

# Normalise the patch to LF in case this repo was checked out with CRLF endings.
$patchLf = Join-Path $env:TEMP "rexglue-sdk-goldeneye.lf.patch"
$patchText = [IO.File]::ReadAllText($PatchFile) -replace "`r`n", "`n"
[IO.File]::WriteAllText($patchLf, $patchText, (New-Object Text.UTF8Encoding $false))

& git -C $SdkDir apply --reverse --check $patchLf 2>$null
if ($LASTEXITCODE -eq 0) {
  Note "GoldenEye SDK patch already applied"
} else {
  & git -C $SdkDir apply --check $patchLf 2>$null
  if ($LASTEXITCODE -ne 0) {
    # An older version of the patch is applied: restore the pristine SDK sources
    # (build output under out\ is kept, so the rebuild is incremental).
    Note "Updating GoldenEye SDK patch"
    Run git -C $SdkDir checkout -q -- .
    $cur = ""
    foreach ($line in ($patchText -split "`n")) {
      if ($line -match "^diff --git a/\S+ b/(\S+)") { $cur = $Matches[1] }
      elseif ($line -match "^new file mode" -and $cur) {
        $f = Join-Path $SdkDir $cur
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
      }
    }
  }
  & git -C $SdkDir apply --whitespace=nowarn $patchLf
  if ($LASTEXITCODE -ne 0) { Die "Could not apply $PatchFile to $SdkDir (is it a different SDK revision?)" }
  Note "Applied GoldenEye SDK patch"
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $SdkInstall ".ge-installed")
}

# --- 3. Build + install the SDK --------------------------------------------------
$Rexglue = Join-Path $SdkInstall "bin\rexglue.exe"
if ((Test-Path (Join-Path $SdkInstall ".ge-installed")) -and (Test-Path $Rexglue)) {
  Bold "ReXGlue SDK already built ($SdkInstall)"
} else {
  Bold "Building ReXGlue SDK (this is the long part, ~15-40 min)"
  Push-Location $SdkDir
  try {
    Run cmake --preset $SdkPreset
    Run cmake --build --preset "$SdkPreset-release" -j $Jobs
  } finally { Pop-Location }
  Run cmake --install $SdkBuild --config Release --prefix $SdkInstall
  New-Item -ItemType File -Force -Path (Join-Path $SdkInstall ".ge-installed") | Out-Null
}

# --- Unpack the XBLA package (needs the SDK's rexglue tool) ------------------------
if ($PackagePath) {
  Bold "Unpacking game package into assets\"
  Run $Rexglue extract $PackagePath $Assets
  if (-not (Test-Path (Join-Path $Assets "default.xex"))) {
    Die "Unpacked the package but found no default.xex in it."
  }
  Note "Unpacked. The original package file can be deleted from assets\ if you copied it there."
}

# --- 4. Recompile the game -------------------------------------------------------
Bold "Recompiling default.xex into C++ (generated\)"
Push-Location $Root
try { Run $Rexglue codegen --max_jump_table_entries 2048 ge_manifest.toml } finally { Pop-Location }

# --- 5. Build GoldenEye.exe ------------------------------------------------------
Bold "Building GoldenEye.exe ($Config, x64)"
if ($Clean -and (Test-Path $GameBuild)) { Remove-Item -Recurse -Force $GameBuild }
Push-Location $Root
try {
  Run cmake --preset $GamePreset "-DCMAKE_PREFIX_PATH=$SdkInstall"
  Run cmake --build --preset $GamePreset -j $Jobs
} finally { Pop-Location }

$Exe = Join-Path $GameBuild "GoldenEye.exe"
if (-not (Test-Path $Exe)) { Die "Build finished but $Exe is missing." }

# Assemble a self-contained folder: GoldenEye.exe + its DLLs + assets\. The game
# finds assets\ next to the exe; ge.toml and logs\ are also written there.
Bold "Packaging GoldenEye-Windows\ (with game files inside)"
$Dist = Join-Path $Root "GoldenEye-Windows"
$saved = $null
if (Test-Path $Dist) {
  # Keep the player's settings across rebuilds.
  $keep = Join-Path $Dist "ge.toml"
  if (Test-Path $keep) { $saved = [IO.File]::ReadAllBytes($keep) }
  Remove-Item -Recurse -Force $Dist
}
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
if ($saved) { [IO.File]::WriteAllBytes((Join-Path $Dist "ge.toml"), $saved) }
Get-ChildItem -LiteralPath $GameBuild -File |
  Where-Object { $_.Extension -in ".exe", ".dll" } |
  Copy-Item -Destination $Dist
$DistAssets = Join-Path $Dist "assets"
New-Item -ItemType Directory -Force -Path $DistAssets | Out-Null
Copy-Item -Path (Join-Path $Assets "*") -Destination $DistAssets -Recurse -Force
# Drop the original packed download (the game doesn't use it) and OS clutter.
Get-ChildItem -LiteralPath $DistAssets -Recurse -File |
  Where-Object { ($_.Length -gt 1MB -and (Test-Stfs $_.FullName)) -or
                 $_.Name -in ".DS_Store", "Thumbs.db", ".gitkeep" } |
  Remove-Item -Force
$assetsMb = [math]::Round(((Get-ChildItem -LiteralPath $DistAssets -Recurse -File |
  Measure-Object Length -Sum).Sum) / 1MB)
$progMb = [math]::Round(((Get-ChildItem -LiteralPath $Dist -File |
  Measure-Object Length -Sum).Sum) / 1MB)

Bold "Done"
Note "Game:   $Dist  (self-contained; move the folder anywhere)"
Note "Size:   $progMb MB program + $assetsMb MB game files"
Note "Launch: $Dist\GoldenEye.exe"
Note "The assets\ folder in the project is only needed to rebuild. Settings (ge.toml)"
Note "and logs\ are written next to GoldenEye.exe."
