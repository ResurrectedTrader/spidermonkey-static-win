<#
.SYNOPSIS
  Build SpiderMonkey as a single static .lib per architecture, linked against the
  STATIC CRT (/MT), for embedding in an injected DLL.

.DESCRIPTION
  Downloads the Firefox ESR source, a no-install MozillaBuild, and a native GNU
  make; configures and builds standalone SpiderMonkey for x86 and/or x64; then
  packages each build into one .lib plus a headers tree under dist-<arch>\.

  Everything lands under -Root. Nothing is installed system-wide except the Rust
  toolchain and cbindgen, which go to the usual rustup/cargo locations.

.PARAMETER Root
  Working directory. MUST be short: Mozilla refuses a source path over 62
  characters (see NOTES). C:\sm leaves plenty of room.

.PARAMETER Arch
  x86, x64, or both (default).

.PARAMETER Version
  Firefox ESR version, e.g. 153.3.0esr.

.PARAMETER Verify
  After building, compile and link a small DLL against the packaged lib and run
  a script through it. x86 verification runs under 32-bit PowerShell.

.PARAMETER Clean
  Remove objdirs and dist output before building (keeps downloads).

.EXAMPLE
  .\build-spidermonkey.ps1 -Arch both -Verify

.NOTES
  Hard-won details this script encodes, each of which fails confusingly otherwise:

  * 62-CHARACTER SOURCE PATH LIMIT. configure.py computes
    260 (MAX_PATH) - 170 (longest objdir-relative path) - 28 (objdir name) = 62.
    Tools like midl.exe ignore LongPathsEnabled, so this is real. `subst` does
    NOT help - mach resolves the real path.

  * MozillaBuild does not need installing. Extracting the NSIS payload with
    7-Zip is enough - but you MUST create msys2\tmp yourself, or its bash prints
    "could not find /tmp" and mach's mozconfig parser dies with a bare
    AssertionError (it asserts on any line before its ------BEGIN_ marker).

  * MozillaBuild 4.x ships NO mozmake, and ftp.mozilla.org's mozmake.exe is 404.
    Cygwin/MSYS make is rejected ("MSYS make is not supported" - baseconfig.mk
    tests whether $(abspath .) starts with /). This script fetches GNU make from
    the MSYS2 *mingw* repo, which is native, plus its libintl/libiconv DLLs.

  * mach blocks forever on a first-run prompt under a non-interactive shell, and
    its mozconfig loader breaks if $SHELL prints anything extra. Both handled.

  * Use the x64-hosted clang-cl for BOTH host and target, even when targeting
    x86. The 32-bit compiler runs out of address space on the unified TUs.

  * js_static.lib is a THIN archive (paths, not objects). MSVC lib.exe rejects it
    as "invalid or corrupt" and llvm-lib crashes on it. Package by listing its
    members and archiving the real objects.

  Consumers of the produced lib must define STATIC_JS_API and XP_WIN, and link
  mincore.lib. NOTE: mozglue supplies DllMain (WindowsDllMain.obj) - a host DLL
  that defines its own will get a duplicate symbol.
#>

[CmdletBinding()]
param(
    [string]$Root    = "C:\sm",
    [ValidateSet('x86', 'x64', 'both')]
    [string]$Arch    = 'both',
    [ValidateSet('Release', 'Debug', 'both')]
    [string]$Config  = 'both',
    [string]$Version = '153.3.0esr',
    [switch]$Verify,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- constants -------------------------------------------------------------

$MAX_SRCDIR_LEN = 62
$MINGW_REPO     = 'https://repo.msys2.org/mingw/mingw64'
$MOZ_FTP        = 'https://ftp.mozilla.org/pub'

function Info  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Ok    { param($m) Write-Host "    $m" -ForegroundColor Green }
function Warn2 { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Die   { param($m) Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# Native tools (rustup, cargo, mach, llvm-*) write progress to stderr. Under
# $ErrorActionPreference='Stop' PowerShell turns that into a terminating
# NativeCommandError even on success, so native calls go through here instead.
function Invoke-Native {
    param([scriptblock]$Script, [string]$What, [switch]$AllowFailure)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Script } finally { $ErrorActionPreference = $prev }
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) { Die "$What failed (exit $LASTEXITCODE)" }
}

function Get-File {
    param($Url, $Dest)
    if (Test-Path $Dest) { Ok "cached: $(Split-Path $Dest -Leaf)"; return }
    Info "downloading $(Split-Path $Dest -Leaf)"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600
}

function Get-SevenZip {
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $p) { return $p }
    }
    Die "7-Zip not found. Install it (needed to unpack the NSIS/zst payloads)."
}

# The MSVC toolset behind that clang-cl, which is the one thing a consumer has
# to match: its STL headers call helpers that live in its own libcpmt.lib, so
# linking against this library needs that toolset or newer. Identified by
# toolset version rather than by Visual Studio year, because the two do not
# correspond - the same toolset ships under more than one year.
function Get-MsvcToolset {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }

    Invoke-Native { $script:vsPath = @(& $vswhere -latest -property installationPath 2>&1) } 'vswhere' -AllowFailure
    Invoke-Native { $script:vsName = @(& $vswhere -latest -property displayName 2>&1) } 'vswhere' -AllowFailure
    $root = $script:vsPath | Where-Object { $_ } | Select-Object -First 1
    if (-not $root) { return $null }

    $toolset = Get-ChildItem (Join-Path $root 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
               Sort-Object { [version]$_.Name } | Select-Object -Last 1
    if (-not $toolset) { return $null }

    $parts = $toolset.Name.Split('.')
    [pscustomobject]@{
        Version = $toolset.Name
        Short   = "$($parts[0]).$($parts[1])"
        Display = ($script:vsName | Where-Object { $_ } | Select-Object -First 1)
    }
}

function Get-LlvmBin {
    # The x64-hosted clang-cl bundled with Visual Studio. Located via vswhere
    # rather than a guessed path: the edition directory differs between
    # installs (Community locally, Enterprise on GitHub-hosted runners), so
    # hardcoding one silently fails on the other.
    $candidates = @()
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        Invoke-Native { $script:vsPaths = @(& $vswhere -products * -latest -property installationPath 2>&1) } 'vswhere' -AllowFailure
        foreach ($p in $script:vsPaths) { if ($p) { $candidates += (Join-Path $p 'VC\Tools\Llvm\x64\bin') } }
    }
    # Fall back to scanning, for installs vswhere does not know about.
    foreach ($root in @("$env:ProgramFiles\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio")) {
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
            Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidates += (Join-Path $_.FullName 'VC\Tools\Llvm\x64\bin')
            }
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'clang-cl.exe'))) { return $c }
    }
    Die ("x64-hosted clang-cl not found. Searched:`n  " + (($candidates | Select-Object -Unique) -join "`n  ") +
         "`nInstall the 'C++ Clang tools for Windows' component - MSVC cannot build SpiderMonkey.")
}

# --- prerequisites ---------------------------------------------------------

function Initialize-Prereqs {
    Info "checking prerequisites"

    $srcPath = Join-Path $Root "firefox-$($Version -replace 'esr$','')"
    if ($srcPath.Length -gt $MAX_SRCDIR_LEN) {
        Die ("source path would be {0} chars ({1}); Mozilla's limit is {2}. Use a shorter -Root." -f `
             $srcPath.Length, $srcPath, $MAX_SRCDIR_LEN)
    }
    Ok "source path $($srcPath.Length) chars (limit $MAX_SRCDIR_LEN)"

    if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { Die "rustup not found. Install from https://rustup.rs/" }

    # A current toolchain is required (ESR 153 rejects anything too old). Install
    # 'stable' alongside whatever the user's default is; never change the default.
    Invoke-Native { rustup toolchain install stable --no-self-update 2>&1 | Out-Null } 'rustup toolchain install'
    foreach ($t in @('x86_64-pc-windows-msvc', 'i686-pc-windows-msvc')) {
        Invoke-Native { rustup target add $t --toolchain stable 2>&1 | Out-Null } "rustup target add $t"
    }
    $rv = $null
    Invoke-Native { $script:rvAll = @(rustup run stable rustc --version 2>&1) } 'rustc --version'
    Ok "rust: $($script:rvAll[0]) (default toolchain left untouched)"

    if (-not (Test-Path "$env:USERPROFILE\.cargo\bin\cbindgen.exe")) {
        Info "installing cbindgen (compiles from source, a minute or two)"
        $env:RUSTUP_TOOLCHAIN = 'stable'
        Invoke-Native { cargo install cbindgen 2>&1 | Write-Host } "cargo install cbindgen"
    }
    Invoke-Native { $script:cbv = (& "$env:USERPROFILE\.cargo\bin\cbindgen.exe" --version 2>&1) } 'cbindgen --version'
    Ok "cbindgen: $script:cbv"

    $py = (Get-Command python -ErrorAction SilentlyContinue)
    $pyWorks = $false
    if ($py) { Invoke-Native { $script:pyv = @(& $py.Source --version 2>&1) } 'python --version' -AllowFailure
               $pyWorks = ($LASTEXITCODE -eq 0 -and "$script:pyv" -match 'Python 3') }
    if (-not $pyWorks) {
        foreach ($c in @("$env:ProgramFiles\Python312\python.exe", "$env:ProgramFiles\Python311\python.exe")) {
            if (Test-Path $c) { $script:Python = $c; break }
        }
    } else { $script:Python = $py.Source }
    if (-not $script:Python) { Die "python 3 not found (note: the Store alias stub does not count)" }
    Invoke-Native { $script:pyver = @(& $script:Python --version 2>&1) } 'python --version'
    Ok "python: $($script:pyver[0])"
}

# --- source + tools --------------------------------------------------------

# Unpacking the Firefox source is a quarter of a million small files, and takes
# ten minutes on one CI image and over ninety on another - three runs were
# cancelled at between 70 and 119 minutes without it finishing. tar says nothing
# at all without -v, so every one of those looked identical from the outside.
#
# Counting tar's own output is not enough: a throttle that prints every N
# entries prints nothing when nothing is coming out, which is the case that
# needs reporting. So tar runs detached with its listing going to a file, and
# the heartbeat comes off a timer instead - it reports every 30 seconds whether
# or not tar has produced anything, and how far the listing has got.
#
# Windows' own bsdtar by full path, never `tar` off PATH. Git, MSYS and Cygwin
# all put a GNU tar there, and GNU tar reads "C:\sm" as a remote host named C
# and goes looking for it:
#     tar (child): Cannot connect to C: resolve failed
# Where that lookup fails fast the build dies early; where it blocks, tar waits
# on it forever having printed nothing, which is what a stalled extract looks
# like from the outside.
# Run a long tool detached and report every thirty seconds how long it has been
# going and how far its output has got - whether or not it has produced any. A
# heartbeat driven by the tool's own output prints nothing in the one case worth
# reporting, which is the tool that has stopped producing output entirely.
function Invoke-Watched {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$What,
        [string]$LogPrefix,
        [string]$Produces
    )
    $outLog = Join-Path $Root "$LogPrefix.out.log"
    $errLog = Join-Path $Root "$LogPrefix.err.log"
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru `
                       -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    # Touching Handle caches it. Without that, Start-Process releases it when the
    # process ends and ExitCode reads back empty - every run looks like a failure
    # whatever the tool actually did.
    $null = $p.Handle

    $started = Get-Date
    while (-not $p.WaitForExit(30000)) {
        $note = ''
        if ($Produces -and (Test-Path $Produces)) {
            $note = ", {0:N0} MB written" -f ((Get-Item $Produces).Length / 1MB)
        } else {
            $bytes = 0
            $tail  = ''
            # bsdtar writes its listing to stderr and GNU tar to stdout, so watch
            # both rather than betting on which one is installed.
            foreach ($f in @($outLog, $errLog)) {
                if (Test-Path $f) {
                    $fi = Get-Item $f
                    $bytes += $fi.Length
                    if ($fi.Length -gt 0) { $tail = Get-Content $f -Tail 1 -ErrorAction SilentlyContinue }
                }
            }
            $note = ", {0,8:N0} KB logged" -f ($bytes / 1KB)
            if ($tail) { $note += ", at $tail" }
        }
        Warn2 ("{0:hh\:mm\:ss} elapsed{1}" -f ((Get-Date) - $started), $note)
    }
    # Reading ExitCode off a Start-Process object is only reliable after the
    # parameterless wait; the timed overload above can leave it unset.
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        foreach ($f in @($errLog, $outLog)) {
            if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { Get-Content $f -Tail 20 | Write-Host }
        }
        Die "$What failed (exit $($p.ExitCode))"
    }
    Ok ("$What finished in {0:hh\:mm\:ss}" -f ((Get-Date) - $started))
}

# Windows ships bsdtar, but which codecs it was built with varies by release,
# and Windows Server 2022's was built without liblzma:
#
#   Server 2022 : bsdtar 3.8.4 - libarchive 3.8.4 zlib/1.2.5.f-ipp cng/2.0 libb2/bundled
#   Windows 11  : bsdtar 3.8.8 - libarchive 3.8.8 zlib/... liblzma/5.8.1 bz2lib/1.0.8 ...
#
# Handed a .tar.xz it cannot decode, it neither extracts anything nor exits -
# three CI runs sat on it for between 70 and 119 minutes and were cancelled,
# having written no files and printed not one line. The same tarball on the
# Server 2025 image, whose bsdtar has liblzma, unpacks in ten minutes.
#
# So the xz and the tar are decoded separately: 7-Zip - already required here
# for the NSIS and zstd payloads - does the xz, and tar unpacks the plain tar it
# leaves behind. One path on every machine, rather than one that depends on how
# the image's tar happened to be compiled.
function Expand-Tarball {
    param([string]$Tarball, [string]$Dest)

    $tarPath = Join-Path (Split-Path $Tarball -Parent) `
                         ((Split-Path $Tarball -Leaf) -replace '\.xz$', '')
    if (-not (Test-Path $tarPath)) {
        Info "decompressing $(Split-Path $Tarball -Leaf) (~4 GB of tar)"
        Invoke-Watched (Get-SevenZip) `
            @('e', '-txz', '-y', "-o$(Split-Path $tarPath -Parent)", $Tarball) `
            'xz decode' 'unxz' $tarPath
    }

    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path $tar)) {
        # Not `tar` off PATH by preference: Git, MSYS and Cygwin all install a
        # GNU tar there, and GNU tar reads a "C:\sm" destination as a remote
        # host named C and goes looking for it.
        $tar = (Get-Command tar -ErrorAction SilentlyContinue).Source
        if (-not $tar) { Die 'no tar: neither System32 nor PATH has one' }
        Warn2 "no bsdtar in System32, falling back to $tar"
    }
    Ok "tar: $tar"
    Invoke-Native { & $tar --version 2>&1 | Select-Object -First 1 | Write-Host } 'tar --version' -AllowFailure

    # Firefox's web-platform test corpus is hundreds of thousands of tiny .html
    # and .ini files, and the standalone JavaScript engine never reads one of
    # them. Timing the heartbeat against the paths it reported, 88 of 155 ticks
    # - 57% of a seventeen-minute unpack - were inside testing/web-platform.
    # Extraction here is bound by per-file cost, not by bytes, so not creating
    # those files is the single largest saving available.
    Info "unpacking $(Split-Path $tarPath -Leaf) (without the web-platform tests)"
    Invoke-Watched $tar `
        @('-xvf', $tarPath, '-C', $Dest, '--exclude', 'firefox-*/testing/web-platform/*') `
        'tar extract' 'extract'
    Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
}

function Get-Sources {
    $7z  = Get-SevenZip
    $dl  = Join-Path $Root 'dl'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null

    # 1. Firefox ESR source
    $tarball = Join-Path $dl "firefox-$Version.source.tar.xz"
    Get-File "$MOZ_FTP/firefox/releases/$Version/source/firefox-$Version.source.tar.xz" $tarball
    $srcDir = Join-Path $Root "firefox-$($Version -replace 'esr$','')"
    if (-not (Test-Path $srcDir)) {
        Info "extracting source (several GB, takes a few minutes)"
        Expand-Tarball $tarball $Root
        if (-not (Test-Path $srcDir)) { Die "extraction did not produce $srcDir" }
    }
    Ok "source: $srcDir"

    # 2. MozillaBuild - extracted, NOT installed (needs no elevation)
    $mb = Join-Path $Root 'mozilla-build'
    if (-not (Test-Path (Join-Path $mb 'msys2\usr\bin\bash.exe'))) {
        $mbExe = Join-Path $dl 'MozillaBuildSetup.exe'
        Get-File "$MOZ_FTP/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe" $mbExe
        Info "extracting MozillaBuild"
        & $7z x $mbExe "-o$mb" -y | Out-Null
    }
    # Its bash warns "could not find /tmp" otherwise, which breaks mach's parser.
    New-Item -ItemType Directory -Force -Path (Join-Path $mb 'msys2\tmp') | Out-Null
    Ok "MozillaBuild: $mb (msys2\tmp present)"

    # 3. Native GNU make. MozillaBuild 4.x ships no mozmake and Mozilla's hosted
    #    copy is gone; cygwin/msys make is rejected by baseconfig.mk.
    $mkBin = Join-Path $Root 'make\mingw64\bin'
    if (-not (Test-Path (Join-Path $mkBin 'mozmake.exe'))) {
        Info "fetching native GNU make from the MSYS2 mingw repo"
        $idx = (Invoke-WebRequest -Uri "$MINGW_REPO/" -UseBasicParsing -TimeoutSec 120).Content
        foreach ($stem in @('make', 'gettext-runtime', 'libiconv')) {
            $pkg = ([regex]::Matches($idx, "mingw-w64-x86_64-$stem-[0-9][^`"<>]*?\.pkg\.tar\.zst") |
                    ForEach-Object { $_.Value } | Sort-Object -Unique | Select-Object -Last 1)
            if (-not $pkg) { Die "could not find package mingw-w64-x86_64-$stem in the mingw repo" }
            $dest = Join-Path $dl $pkg
            Get-File "$MINGW_REPO/$pkg" $dest
            & $7z x $dest "-o$dl" -y | Out-Null
            & $7z x (Join-Path $dl ($pkg -replace '\.zst$','')) "-o$(Join-Path $Root 'make')" -y | Out-Null
        }
        # Mozilla looks for mozmake/gmake/make; give it an unambiguous name.
        Copy-Item (Join-Path $mkBin 'mingw32-make.exe') (Join-Path $mkBin 'mozmake.exe') -Force
    }
    Invoke-Native { $script:mkAll = @(& (Join-Path $mkBin 'mozmake.exe') --version 2>&1) } 'mozmake --version'
    $mkVer = $script:mkAll[0]
    Ok "make: $mkVer (native)"

    return @{ Src = $srcDir; MozillaBuild = $mb; MakeBin = $mkBin }
}

# --- build -----------------------------------------------------------------

function New-Mozconfig {
    param($Arch, $Config, $Path, $ObjDirName)
    $target = if ($Arch -eq 'x86') { 'i686-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
    # A host using MultiThreadedDebug (/MTd) for Debug and MultiThreaded (/MT)
    # for Release needs the engine to match, or the CRTs conflict at link.
    if ($Config -eq 'Debug') {
        $dbg = "ac_add_options --enable-debug`nac_add_options --disable-optimize"
        $crt = '-MTd'
    } else {
        $dbg = "ac_add_options --disable-debug`nac_add_options --enable-optimize"
        $crt = '-MT'
    }
    @"
# Standalone SpiderMonkey, $Arch $Config, static CRT. Generated by build-spidermonkey.ps1.
ac_add_options --enable-project=js
$dbg
ac_add_options --disable-jemalloc
ac_add_options --disable-shared-js
ac_add_options --disable-tests
ac_add_options --target=$target

# Static CRT on BOTH halves - the C++ side and the Rust (jsrust) side must agree.
export CFLAGS="$crt"
export CXXFLAGS="$crt"
export RUSTFLAGS="-Ctarget-feature=+crt-static"

mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/../$ObjDirName
"@ | Set-Content -Encoding ascii $Path
}

function Invoke-MachBuild {
    param($Arch, $Config, $Paths)

    $tag     = "$Arch-$($Config.ToLower())"
    $objName = "obj-$tag"
    $objDir  = Join-Path $Root $objName
    $mozcfg  = Join-Path $Root "mozconfig.$tag"
    New-Mozconfig -Arch $Arch -Config $Config -Path $mozcfg -ObjDirName $objName

    if ($Clean -and (Test-Path $objDir)) {
        Info "cleaning $objDir"
        [System.IO.Directory]::Delete($objDir, $true)
    }

    $llvm = Get-LlvmBin
    # x64-hosted clang-cl for BOTH host and target: the 32-bit compiler runs out
    # of address space on SpiderMonkey's unified translation units.
    $env:PATH                = "$($Paths.MakeBin);$llvm;$env:USERPROFILE\.cargo\bin;$env:PATH"
    $env:RUSTUP_TOOLCHAIN    = 'stable'
    $env:MOZBUILD_STATE_PATH = Join-Path $Root '.mozbuild'
    $env:MOZCONFIG           = $mozcfg
    $env:MOZILLABUILD        = $Paths.MozillaBuild
    $env:SHELL               = Join-Path $Paths.MozillaBuild 'msys2\usr\bin\bash.exe'
    $env:TMPDIR              = Join-Path $Root 'tmp'
    New-Item -ItemType Directory -Force -Path $env:MOZBUILD_STATE_PATH, $env:TMPDIR | Out-Null
    # Suppress mach's first-run telemetry prompt; it blocks on stdin forever.
    'telemetry=false' | ForEach-Object { "[build]`n$_" } |
        Set-Content -Encoding ascii (Join-Path $env:MOZBUILD_STATE_PATH 'machrc')

    Push-Location $Paths.Src
    try {
        # Teed rather than redirected: mach is the long pole, and a step that
        # prints nothing for an hour cannot be told apart from one that has hung
        # - which matters here, because mach is known to block forever on a
        # first-run prompt under a non-interactive shell. The log is only
        # collected after the job ends, far too late to make that call.
        $cfgLog = Join-Path $Root "cfg-$tag.log"
        Info "configure ($Arch $Config)"
        Invoke-Native {
            & $script:Python -u ./mach configure 2>&1 | Tee-Object -FilePath $cfgLog | Out-Host
        } 'configure' -AllowFailure
        if ($LASTEXITCODE -ne 0) { Die "configure failed ($tag); see cfg-$tag.log" }
        Ok "configure complete"

        $buildLog = Join-Path $Root "build-$tag.log"
        Info "build ($Arch $Config) - this takes a while"
        Invoke-Native {
            & $script:Python -u ./mach build 2>&1 | Tee-Object -FilePath $buildLog | Out-Host
        } 'build' -AllowFailure
        if ($LASTEXITCODE -ne 0) { Die "build failed ($tag); see build-$tag.log" }
        Ok "build complete"
    } finally { Pop-Location }

    return $objDir
}

# --- packaging -------------------------------------------------------------

function New-MergedLib {
    param($Arch, $Config, $ObjDir)
    $tag = "$Arch-$($Config.ToLower())"

    $llvm    = Get-LlvmBin
    $llvmAr  = Join-Path $llvm 'llvm-ar.exe'
    $llvmLib = Join-Path $llvm 'llvm-lib.exe'
    $dist    = Join-Path $Root "dist-$tag"
    $triple  = if ($Arch -eq 'x86') { 'i686-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }

    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Info "packaging ($Arch $Config)"

    $inputs = New-Object System.Collections.Generic.List[string]

    # js_static.lib and pure_virtual.lib are THIN archives: their "members" are
    # absolute paths to objects on disk. Archive those objects directly - MSVC
    # lib.exe calls a thin archive corrupt and llvm-lib crashes on one.
    foreach ($lib in @("$ObjDir\js\src\build\js_static.lib", "$ObjDir\build\pure_virtual\pure_virtual.lib")) {
        if (-not (Test-Path $lib)) { continue }
        $members = $null
        Invoke-Native { $script:members = (& $llvmAr t $lib 2>&1) } 'llvm-ar t' -AllowFailure
        $script:members | ForEach-Object {
            $m = $_.Trim().Replace('\', '/')
            if ($m -and [System.IO.Path]::IsPathRooted($m)) { $inputs.Add($m) }
        }
    }

    # The shell's link list names objects that are NOT inside js_static.lib
    # (mfbt, memory, mozglue/misc, baseprofiler, fmt). zlib appears in both, so
    # take it only from the archive to avoid duplicate symbols.
    $listFile = "$ObjDir\js\src\shell\js_exe.list"
    if (-not (Test-Path $listFile)) { Die "missing $listFile - did the build finish?" }
    Get-Content $listFile | ForEach-Object {
        $t = $_.Trim().Replace('\', '/')
        if (-not $t -or $t -match 'Unified_cpp_js_src_shell' -or $t -match '/modules/zlib/') { return }
        $inputs.Add(([System.IO.Path]::GetFullPath((Join-Path "$ObjDir\js\src\shell" $t))).Replace('\', '/'))
    }

    # jsrust.lib is a NORMAL archive, so it has to be extracted.
    # Cargo writes into its own profile directory: debug/ for a debug build.
    $rustProfile = if ($Config -eq 'Debug') { 'debug' } else { 'release' }
    $rustLib = "$ObjDir\$triple\$rustProfile\jsrust.lib"
    if (-not (Test-Path $rustLib)) { Die "missing $rustLib" }
    $ex = Join-Path $Root "extract-$tag\rust"
    if (Test-Path $ex) { [System.IO.Directory]::Delete($ex, $true) }
    New-Item -ItemType Directory -Force -Path $ex | Out-Null
    Push-Location $ex
    try { Invoke-Native { & $llvmAr x $rustLib 2>&1 | Out-Null } 'llvm-ar x' } finally { Pop-Location }
    Get-ChildItem $ex -File | ForEach-Object { $inputs.Add($_.FullName.Replace('\', '/')) }

    $uniq    = $inputs | Sort-Object -Unique
    $missing = $uniq | Where-Object { -not (Test-Path $_) }
    if ($missing) { Die "$($missing.Count) inputs missing, first: $($missing[0])" }

    $outLib = Join-Path $dist 'spidermonkey.lib'
    $rsp    = Join-Path $Root "merge-$tag.rsp"
    $lines  = @("/OUT:$($outLib.Replace('\','/'))")
    if ($Arch -eq 'x86') { $lines += '/MACHINE:X86' }
    $lines += $uniq
    $lines | Set-Content -Encoding ascii $rsp

    Invoke-Native { & $llvmLib "@$rsp" 2>&1 | Out-Null } "llvm-lib ($tag)"
    Ok ("{0} ({1:N1} MB, {2} objects)" -f $outLib, ((Get-Item $outLib).Length / 1MB), $uniq.Count)

    # Headers alongside the lib, so consumers need only this one directory.
    $incOut = Join-Path $dist 'include'
    if (Test-Path $incOut) { [System.IO.Directory]::Delete($incOut, $true) }
    Copy-Item "$ObjDir\dist\include" $incOut -Recurse
    Ok "headers: $incOut"

    $toolset   = Get-MsvcToolset
    $builtWith = if ($toolset) { "$($toolset.Version)  ($($toolset.Display))" } else { 'unknown' }

    @"
SpiderMonkey $Version ($Arch $Config), static CRT ($(if ($Config -eq 'Debug') { '/MTd' } else { '/MT' })).

  link against : spidermonkey.lib
  include path : include
  required defines : STATIC_JS_API  XP_WIN$(if ($Config -eq 'Debug') { '  DEBUG' })
  built with       : MSVC $builtWith
  extra system libs: mincore.lib (QueryUnbiasedInterruptTimePrecise)
                     plus ws2_32 advapi32 user32 ole32 oleaut32 shell32
                     userenv bcrypt ntdll dbghelp psapi winmm shlwapi

Link this with MSVC $(if ($toolset) { $toolset.Short } else { 'the same toolset' }) or newer. An older toolset fails with
undefined __std_* symbols: the STL headers this was compiled against call
helpers that ship in that toolset's own libcpmt.lib. The toolset version is what
matters, not the Visual Studio year - one toolset ships under several years.

$(if ($Config -eq 'Debug') { @'
NOTE: a debug engine requires DEBUG to be defined by the consumer. js-config.h
hard-errors without it. MSVC defines _DEBUG, not DEBUG, so add it explicitly.

'@ })CAUTION: mozglue defines DllMain (WindowsDllMain.obj). A host DLL that defines
its own DllMain will fail to link with a duplicate symbol. Either drop yours and
let mozglue's run, or exclude that object when packaging.

Built from firefox-$Version with:
  CFLAGS/CXXFLAGS = $(if ($Config -eq 'Debug') { '-MTd' } else { '-MT' })
  RUSTFLAGS       = -Ctarget-feature=+crt-static
"@ | Set-Content -Encoding ascii (Join-Path $dist 'README.txt')

    # Machine-readable counterpart to the "built with" line above, so packaging
    # can label an archive with the toolset it needs without re-deriving it.
    if ($toolset) { $toolset.Short | Set-Content -Encoding ascii (Join-Path $dist 'toolset.txt') }

    return $outLib
}

# --- verification ----------------------------------------------------------

function Test-Package {
    param($Arch, $Config, $Lib)
    $crtFlag = if ($Config -eq 'Debug') { '/MTd' } else { '/MT' }

    $llvm = Get-LlvmBin
    $dist = Split-Path $Lib -Parent
    $work = Join-Path $Root "verify-$Arch-$($Config.ToLower())"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Info "verifying ($Arch $Config)"

    @'
#include "jsapi.h"
#include "js/Initialization.h"
#include "js/CompilationAndEvaluation.h"
#include "js/SourceText.h"

// No DllMain here on purpose: mozglue supplies one.
extern "C" __declspec(dllexport) int SpikeRun() {
    if (!JS_Init()) return 1;
    JSContext* cx = JS_NewContext(8L * 1024 * 1024);
    if (!cx) return 2;
    if (!JS::InitSelfHostedCode(cx)) return 3;
    int rc = 0;
    {
        JS::RealmOptions options;
        static JSClass globalClass = {"global", JSCLASS_GLOBAL_FLAGS, &JS::DefaultGlobalClassOps};
        JS::RootedObject global(cx, JS_NewGlobalObject(cx, &globalClass, nullptr,
                                                       JS::FireOnNewGlobalHook, options));
        if (!global) rc = 4;
        else {
            JSAutoRealm ar(cx, global);
            JS::CompileOptions opts(cx);
            opts.setFileAndLine("verify.js", 1);
            JS::SourceText<mozilla::Utf8Unit> src;
            const char code[] = "40 + 2";
            if (!src.init(cx, code, sizeof(code) - 1, JS::SourceOwnership::Borrowed)) rc = 5;
            else {
                JS::RootedValue rval(cx);
                if (!JS::Evaluate(cx, opts, src, &rval)) rc = 6;
                else rc = (rval.isInt32() && rval.toInt32() == 42) ? 0 : 7;
            }
        }
    }
    JS_DestroyContext(cx);
    JS_ShutDown();
    return rc;
}
'@ | Set-Content -Encoding ascii (Join-Path $work 'verify.cpp')

    Push-Location $work
    try {
        # Build the argument list as one array; mixing inline splatting with
        # literal args mangles the native command line.
        $cargs = @('-c')
        if ($Arch -eq 'x86') { $cargs += '-m32' }
        # js-config.h hard-errors unless DEBUG is defined for a --enable-debug
        # engine. Note MSVC defines _DEBUG, not DEBUG, so consumers must add it.
        if ($Config -eq 'Debug') { $cargs += '/DDEBUG' }
        $cargs += @($crtFlag, '/std:c++20', '/EHsc', '/GR-', '/nologo',
                    '/DSTATIC_JS_API', '/DXP_WIN', '/DWIN32', '/D_WINDOWS',
                    "/I$dist\include", 'verify.cpp', '/Foverify.obj')
        Invoke-Native {
            & "$llvm\clang-cl.exe" @cargs 2>&1 | Where-Object { $_ -match 'error' } | Out-Host
        } 'verify compile' -AllowFailure
        if (-not (Test-Path 'verify.obj')) { Die "verify compile failed ($Arch $Config)" }

        $sys = @('ws2_32','advapi32','user32','kernel32','ole32','oleaut32','shell32','userenv','bcrypt',
                 'ntdll','dbghelp','psapi','winmm','version','normaliz','crypt32','secur32','shlwapi',
                 'delayimp','mincore') | ForEach-Object { "$_.lib" }
        $args = @('/DLL', '/OUT:verify.dll', '/NOLOGO', '/SUBSYSTEM:WINDOWS')
        if ($Arch -eq 'x86') { $args += '/MACHINE:X86' }
        $args += 'verify.obj'; $args += $Lib; $args += $sys
        $args | Set-Content -Encoding ascii 'verify.rsp'
        Invoke-Native { & "$llvm\lld-link.exe" '@verify.rsp' 2>&1 | Where-Object { $_ -match 'error' } | Out-Host } 'verify link' -AllowFailure
        if (-not (Test-Path 'verify.dll')) { Die "verify link failed ($Arch $Config)" }

        Invoke-Native {
            $script:crt = (& "$llvm\llvm-readobj.exe" --coff-imports verify.dll 2>&1 |
                           Select-String -Pattern 'vcruntime|msvcp|msvcr|api-ms-win-crt').Count
        } 'readobj' -AllowFailure
        $crt = $script:crt
        if ($crt -ne 0) { Die "verify.dll has $crt dynamic-CRT imports - /MT did not take" }
        Ok "linked, 0 dynamic-CRT imports"

        $runner = @"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class V {
    [DllImport(@"$work\verify.dll", EntryPoint="SpikeRun", CallingConvention=CallingConvention.Cdecl)]
    public static extern int Run();
}
'@
exit [V]::Run()
"@
        $runner | Set-Content -Encoding ascii 'run.ps1'
        # A 32-bit DLL needs a 32-bit host process.
        $ps = if ($Arch -eq 'x86') { "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" }
              else                 { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
        Invoke-Native { & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'run.ps1') } 'verify run' -AllowFailure
        if ($LASTEXITCODE -ne 0) { Die "verify.dll ran but returned $LASTEXITCODE (expected 0)" }
        Ok "executed JavaScript successfully (40 + 2 == 42)"
    } finally { Pop-Location }
}

# --- main ------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $Root | Out-Null
$Root = (Resolve-Path $Root).Path
Info "root: $Root"

Initialize-Prereqs
$paths = Get-Sources

$targets = if ($Arch   -eq 'both') { @('x64', 'x86') }        else { @($Arch) }
$configs = if ($Config -eq 'both') { @('Release', 'Debug') } else { @($Config) }
$built   = [ordered]@{}
foreach ($a in $targets) {
    foreach ($c in $configs) {
        $obj = Invoke-MachBuild -Arch $a -Config $c -Paths $paths
        $built["$a-$($c.ToLower())"] = @{
            Lib = (New-MergedLib -Arch $a -Config $c -ObjDir $obj); Arch = $a; Config = $c
        }
    }
}
if ($Verify) {
    foreach ($k in $built.Keys) { Test-Package -Arch $built[$k].Arch -Config $built[$k].Config -Lib $built[$k].Lib }
}

Info "done"
foreach ($k in $built.Keys) { Ok "$k -> $($built[$k].Lib)" }
