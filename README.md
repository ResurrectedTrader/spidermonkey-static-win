# spidermonkey-static-win

Build modern SpiderMonkey on Windows as a **single static `.lib` per
configuration**, linked against the **static CRT**, so it can be embedded in a
DLL that carries no `vcruntime140.dll` / `msvcp140.dll` dependency.

Produces the matrix `{x86, x64}` × `{Release, Debug}`, each as one library plus
its headers — ready to vendor the way a V8 monolith is.

```powershell
.\build-spidermonkey.ps1 -Root C:\sm -Arch both -Config both -Verify
```

Verified against **Firefox ESR 153.3.0**: every configuration links into a DLL
that imports zero CRT DLLs and successfully executes JavaScript. A manual GitHub
Actions workflow (`.github/workflows/build.yml`) builds the matrix and can
publish the archives as release assets.

Output per configuration, under `dist-<arch>-<config>\`:

| File | Purpose |
|---|---|
| `spidermonkey.lib` | everything, one archive |
| `include\` | the `dist/include` headers (665 files) |
| `README.txt` | the defines and system libs a consumer needs |

Budget roughly an hour per configuration on fast hardware. `-Arch` and `-Config`
each take `both` or a single value, so the matrix can be built a piece at a time.

## Prerequisites

| Requirement | Notes |
|---|---|
| Visual Studio with ClangCL | MSVC proper **cannot** build SpiderMonkey any more. The script uses the x64-hosted `clang-cl` for both host and target. |
| 7-Zip | Unpacks the NSIS and `.zst` payloads. |
| Rust via rustup | The script installs a `stable` toolchain and both targets. **It does not change your default toolchain.** |
| Python 3 | Runs `mach`. The Windows Store `python` stub does not count. |
| ~40 GB disk | Four object directories dominate; they can be deleted after packaging. |

Everything else — the Firefox source, MozillaBuild, GNU make — is downloaded into
`-Root`. Nothing is installed system-wide except the Rust toolchain and
`cbindgen`, which go to the usual `~/.rustup` and `~/.cargo`.

## How it works

`build-spidermonkey.ps1` runs five stages. Everything it downloads or produces
stays under `-Root`; nothing is installed system-wide except the Rust toolchain
and `cbindgen`.

**1. Prerequisites.** Verifies the source path will be short enough (see trap 1),
installs a `stable` Rust toolchain plus the `i686` and `x86_64` targets *without
changing your default toolchain*, installs `cbindgen`, and locates a real
Python 3 and an x64-hosted `clang-cl`.

**2. Acquire.** Downloads and unpacks three things:

| What | Where from | Why it is not just "install it" |
|---|---|---|
| Firefox ESR source | `ftp.mozilla.org` | ~4.4 GB extracted; contains `js/src` and `mach` |
| MozillaBuild | `ftp.mozilla.org` | extracted with 7-Zip, never installed — no elevation, no `C:\mozilla-build` |
| GNU make 4.4.1 | MSYS2 *mingw* repo | MozillaBuild no longer ships `mozmake`, and MSYS make is rejected |

**3. Configure.** Writes a `mozconfig` per `<arch>-<config>` selecting standalone
SpiderMonkey (`--enable-project=js`), the target triple, and — the point of the
exercise — the static CRT on both the C++ and Rust halves. Then runs
`mach configure` with a pinned state directory and a quiet shell.

**4. Build.** `mach build`. Output lands in `obj-<arch>-<config>`.

**5. Package.** This is the step that makes the result *vendorable*. A normal
build produces working artifacts, but they are only usable in place: the main
library is a **thin archive** of absolute paths into the object directory, and it
is not self-contained anyway. The script resolves the real object list — from the
archive's members, the shell's link list, and the extracted Rust archive — and
emits a single `spidermonkey.lib` plus the headers. See trap 7.

**`-Verify`** then compiles a small DLL against the packaged output with the
matching CRT flag, links it, asserts it imports no CRT DLL, and executes
`40 + 2` through the engine. A 32-bit DLL needs a 32-bit host process, so the
x86 check runs under `SysWOW64\WindowsPowerShell`.

Each stage is skippable on re-runs: downloads are cached, and an existing object
directory builds incrementally.

## What the script does, and the traps it avoids

Each of these fails in a way that does not point at its own cause, which is why
they are worth writing down.

### 1. The source path must be 62 characters or fewer

`configure.py` computes `260 (MAX_PATH) - 170 (longest objdir-relative path) -
28 (objdir name) = 62` and refuses anything longer. The comment in the source is
explicit that `midl.exe` and friends ignore `LongPathsEnabled`, so this is a real
constraint rather than caution.

`subst`-ing a short drive letter does **not** work — `mach` resolves the real
path. The tree has to physically live somewhere short. The script checks this
first and fails immediately rather than 20 minutes in.

### 2. MozillaBuild does not need installing

The installer wants elevation. Extracting its NSIS payload with 7-Zip gives the
same tools with no elevation, no `C:\mozilla-build`, and no registry or PATH
changes.

One catch: **you must create `msys2\tmp` yourself.** The installer makes it; the
payload does not contain it. Without it, MozillaBuild's bash prints

```
bash.exe: warning: could not find /tmp, please create!
```

`mach` sources your mozconfig through `$SHELL` and parses the environment dump
between `------BEGIN_`/`------END_` markers, asserting on any line that appears
before the first marker. That warning is such a line, so you get a bare
`AssertionError` from `mozconfig.py` with no indication of the cause.

For the same reason `$SHELL` must be a *quiet* shell — one whose profile prints
anything will break the parse.

### 3. There is no `mozmake` any more

MozillaBuild 4.x ships none, and
`ftp.mozilla.org/pub/mozilla/libraries/win32/mozmake.exe` returns 404. Meanwhile
`config/baseconfig.mk` rejects MSYS/cygwin make:

```make
ifeq (a,$(firstword a$(subst /, ,$(abspath .))))
$(error MSYS make is not supported)
endif
```

That tests whether `$(abspath .)` starts with `/`. Cygwin make answers
`/cygdrive/c/...` and is refused; a native make answers `C:/...` and passes.

The script fetches GNU make **4.4.1** from the MSYS2 *mingw* repository (native,
unlike MSYS2's own `usr/bin/make`) plus its `libintl-8` / `libiconv-2` DLLs, and
copies it to `mozmake.exe`. It does not touch an existing MSYS2 installation.

### 4. `mach` blocks on a first-run prompt

Under a non-interactive shell it waits forever for a telemetry answer. The script
writes a `machrc` with `telemetry=false` into the pinned state directory, and
pins `MOZBUILD_STATE_PATH` into `-Root` so mach's virtualenvs and caches do not
land in `%USERPROFILE%\.mozbuild`.

### 5. Use x64-hosted tools even for the 32-bit build

The script sets host and target compiler to the same `Llvm\x64\bin\clang-cl.exe`
and selects the architecture with `--target=i686-pc-windows-msvc`. SpiderMonkey's
unified translation units are large enough that a 32-bit compiler can exhaust its
address space.

### 6. The static CRT, which is the whole point

```
export CFLAGS="-MT"      # -MTd for a Debug build
export CXXFLAGS="-MT"
export RUSTFLAGS="-Ctarget-feature=+crt-static"
```

Both halves must agree. `js_static.lib` is C++; `jsrust.lib` is Rust. Check with:

```powershell
llvm-readobj --coff-directives js_static.lib | Select-String defaultlib
```

Release wants `libcmt` / `libcpmt`; Debug wants `libcmtd` / `libcpmtd`. Either
way, **zero** occurrences of `msvcrt` / `msvcprt`.

The Debug case was expected to break, because `-Ctarget-feature=+crt-static` has
no debug variant on MSVC targets — so the Rust half could plausibly have insisted
on the release CRT while the C++ half used the debug one. **It does not.** Rust
follows Mozilla's debug profile and emits `libcmtd`, matching.

Two Debug-only wrinkles:

* Cargo writes `jsrust.lib` into its own profile directory — `debug/`, not
  `release/`. Packaging has to follow.
* A debug engine **requires the consumer to define `DEBUG`**. `js-config.h`
  hard-errors otherwise, and MSVC defines `_DEBUG`, not `DEBUG`, so it must be
  added explicitly.

### 7. Packaging: `js_static.lib` is a *thin* archive

Its members are absolute paths to objects on disk, not the objects themselves —
14.7 MB of index referencing 582.5 MB of objects. Consequences:

* MSVC `lib.exe` reports `LNK1136: invalid or corrupt file`.
* `llvm-lib` crashes with an access violation.
* Copying it elsewhere gives you a file full of paths that no longer exist.

That last point is why repackaging is necessary for vendoring at all. A normal
build produces perfectly good artifacts, but they are only usable *in place*.

So the script builds the object list instead:

| Source | Count (x64 Release) | How |
|---|---|---|
| `js_static.lib` members | 547 | `llvm-ar t` gives absolute paths; archive those objects |
| `pure_virtual.lib` | 1 | same |
| `js_exe.list` extras | 32 | `mfbt`, `memory`, `mozglue/misc`, `baseprofiler`, `fmt` |
| `jsrust.lib` members | 281 | a *normal* archive, so extract it |
| **total** | **861** | one `llvm-lib` invocation |

`obj-<tag>\js\src\shell\js_exe.list` is the authoritative list of what a real
SpiderMonkey binary links. `js_static.lib` is **not** self-contained: it bundles
ICU, zlib, fdlibm and `mozglue/static`, but not `mfbt`, `memory` or
`mozglue/misc`.

zlib appears in both `js_static.lib` and `js_exe.list`; the script takes it only
from the archive, or the link fails with duplicate symbols.

Counts differ per configuration (Debug pulls ~100 more objects), so the list is
derived from each build rather than hardcoded.

## Consuming the result

```
/DSTATIC_JS_API        # or JS_PUBLIC_API becomes __declspec(dllimport)
/DXP_WIN               # or headers take the POSIX branch and want <pthread.h>
/DDEBUG                # Debug only; js-config.h hard-errors without it
/MT (Release)  /MTd (Debug)        # must match how the engine was built
/I <dist>\include

link: spidermonkey.lib mincore.lib ws2_32.lib advapi32.lib user32.lib ole32.lib
      oleaut32.lib shell32.lib userenv.lib bcrypt.lib ntdll.lib dbghelp.lib
      psapi.lib winmm.lib shlwapi.lib
```

`mincore.lib` supplies `QueryUnbiasedInterruptTimePrecise`, used by
`mozglue/misc/AwakeTimeStamp.cpp`.

### `DllMain`: a non-problem, but only if you link the archive

`mozglue/misc/WindowsDllMain.obj` defines `DllMain`. If you link the objects
*explicitly* — straight out of the objdir, the way `js_exe.list` names them — a
host DLL with its own `DllMain` fails with:

```
lld-link: error: duplicate symbol: DllMain
```

Inside the packaged archive it is a **member**, and a linker only pulls a member
to resolve an *undefined* symbol. Your `DllMain` already satisfies the CRT's
reference, so mozglue's is never pulled. Verified: a DLL with its own `DllMain`
links against `spidermonkey.lib`, runs its own `DllMain` on attach, initialises
the engine, and still imports no CRT DLL.

So packaging does not merely make the library relocatable — it removes this
conflict. Linking from the objdir reintroduces it.

What you give up is what mozglue's `DllMain` does, which is two things:

```cpp
::DisableThreadLibraryCalls(aInstDll);
::LoadLibraryExW(L"cryptbase.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
```

The first suppresses per-thread notifications — usually unwanted in a host that
tracks threads. The second is a DLL-hijack mitigation aimed at Firefox's own
installation directory, where `RtlGenRandom` (imported from advapi32 as
`SystemFunction036`) is really implemented in `cryptbase.dll`. Neither is
required; the preload is one `LoadLibraryExW` call if you want it.

## Verified results

`-Verify` compiles a small DLL against the packaged lib with the matching CRT
flag, links it, checks it imports no CRT DLL, and executes `40 + 2` through the
engine. A 32-bit DLL can only be loaded by a 32-bit process, so the x86
verification runs under `SysWOW64\WindowsPowerShell`.

| Configuration | Merged lib | Objects | CRT | CRT DLL imports | Runs JS |
|---|---|---|---|---|---|
| x64 Release | 631 MB | 861 | `libcmt` | 0 | yes |
| x86 Release | 629 MB | 860 | `libcmt` | 0 | yes |
| x64 Debug | 1,195 MB | 963 | `libcmtd` | 0 | yes |
| x86 Debug | 1,130 MB | 962 | `libcmtd` | 0 | yes |

Value representation is `JS_PUNBOX64` on x64 and `JS_NUNBOX32` on x86, and the
x86 DLLs report `IMAGE_FILE_MACHINE_I386` — these are genuine 32-bit builds with
the x86 JITs, not a 64-bit build mislabelled.

### Size

The whole matrix is ~3.6 GB. For scale, a comparable V8 monolith matrix is
~5.6 GB, so SpiderMonkey is roughly half the size.

The archives are large because the build embeds debug info (`/Z7`) in every
object even in Release — Mozilla ships symbols for crash reporting. The linked
DLL is ~30 MB, so the payload is far smaller than the archive suggests.

## Continuous integration

`.github/workflows/build.yml` is `workflow_dispatch` only. A full matrix is about
an hour per configuration on fast hardware and considerably longer on a 4-vCPU
hosted runner, while the output only changes when the ESR line moves — a few
times a year. Consumers download published assets; they do not build.

Notes for the hosted runners specifically:

* **clang-cl is checked first.** The image ships Visual Studio, but whether the
  C++ Clang tools component is included has varied, and MSVC cannot build
  SpiderMonkey. Better to fail in seconds than in an hour.
* **Disk is tight.** A Debug configuration needs roughly 9 GB (3.4 GB source,
  2.5 GB objdir, 1.2 GB output, plus MozillaBuild and downloads) against about
  14 GB free. The workflow reclaims some space first.
* **The build root is `C:\sm`**, not the workspace — the 62-character source path
  limit rules out a path under `D:\a\<repo>\<repo>`.
* Each archive is well under the 2 GiB per-asset limit; a combined one would not
  be, so they are published separately.

## Version

Built and verified against **Firefox ESR 153.3.0** (`MOZJS_MAJOR_VERSION 153`)
with clang-cl 20.1.8, Rust 1.98.1 stable, cbindgen 0.29.4, GNU make 4.4.1.

Mozilla still ships `win32/` builds and a 32-bit JS shell for this ESR, and
`i686-pc-windows-msvc` remains a Rust Tier 1 target, so 32-bit is supported
upstream rather than merely incidental.
