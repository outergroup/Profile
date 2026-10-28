# Profile

Profile records Linux perf stack samples and displays CPU timelines and flame graphs through HTML and outerframe frontends.

## Recording URLs and storage

Both frontends use `/traces/<recording-id>` for trace pages and `/` for Next Recording. The backend serves HTML or the outerframe descriptor at each document path according to the request's Accept header. Selecting a trace adds browser history; reloads and history navigation restore that trace.

Completed recordings, including original sample timestamps, stack frames, container metadata, and capture diagnostics, are stored in a versioned offset-based binary file named `recordings.bin`. Writes use a temporary file, fsync, and atomic rename. A lock prevents two backends from writing the same store. Invalid or unsupported stores cause startup to fail without overwriting them.

Storage uses `--state-dir DIR` when supplied, otherwise `OUTERSHELL_SERVICE_STATE_DIR`, `$XDG_STATE_HOME/<label>`, or `$HOME/.local/state/<label>`. Keep this directory outside deployment bundles. The existing 32-recording retention limit also applies to saved recordings; deletion and eviction persist across restarts. Recording IDs are reserved durably and never reused after deletion or restart. An in-progress capture is not a completed recording and does not survive backend termination.

To run the storage and routing regression tests:

```sh
cc -std=gnu17 -g -fsanitize=address,undefined Scripts/test_profile_storage.c -o /tmp/test-profile-storage -lm -pthread
/tmp/test-profile-storage
node Scripts/test_trace_navigation.cjs
```

## Build

```bash
./build_run.sh
```

## Deploy Over SSH

With a current Outer Shell installed on the target:

```bash
./app target "ssh -p 22 you@server"
./app deploy
```

The deploy target is stored in the gitignored `target.env`. Deployment detects
the target architecture and libc and builds only the matching dynamic backend.
glibc builds use the manylinux2014 (glibc 2.17) baseline; musl builds use
musllinux 1.2. Run `./app build-matrix` to build all four Linux release
variants, or `./app help` for the other development commands.

## Run

```bash
PORT=7354
./build/macos/Release/ProfileBackend --port "$PORT" --bundles-dir ./build/run/bundles
```

Open this URL in Outer Loop or Outer Frame:

```text
http://127.0.0.1:7354/
```

For Outer Loop-managed deployments, prefer a Unix socket. If `--port` is omitted, Profile listens directly under `$XDG_RUNTIME_DIR` using the backend label:

```bash
./build/macos/Release/ProfileBackend \
  --label org.outershell.Profile \
  --bundles-dir ./build/run/bundles
```

You can also pass an explicit socket:

```bash
./build/macos/Release/ProfileBackend \
  --socket-path "$XDG_RUNTIME_DIR/org.outershell.Profile" \
  --label org.outershell.Profile \
  --bundles-dir ./build/run/bundles
```

The backend serves the outerframe descriptor, the archived macOS content bundles, `/api/files?path=...`, and `/api/openers?path=...` from the same loopback HTTP server. Profile queries outershelld's socket API directly for opener registry entries, using `OUTERSHELLD_API_SOCKET` when set or the platform default API socket path otherwise.

To create a release payload for a Home Screen-style installer, build both Linux
backend architectures into `build/linux-package/RemoteLinuxBinaries`, then run:

```bash
./Scripts/package_release.sh
```

The archive is written to `build/release/Profile.tar.gz`. Deployment-specific
publishing should live outside this repository.

## Remote Development

To test a deployed remote host with curl:

```bash
ssh "$HOST" 'curl --unix-socket "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/org.outershell.Profile" http://localhost/'
```

## Container-aware HTML view

On Linux, the process picker groups host-visible processes by Docker container using cgroups and Outer Shell's binary registry API. It displays container-local PIDs while recording against host PIDs. The HTML client supplies the selected process's start time and container identity; the backend rejects a stale selection before starting perf. Discovery runs in a background thread and refreshes every five seconds.

Recordings retain their container identity, name, and local PID. `perf record --namespaces` records namespace information so perf can resolve binaries inside the target's filesystem. Symbols still depend on permissions, available binaries/debug information, and the installed perf version. Existing perf permission requirements apply; the app does not grant container capabilities or elevate itself. This path supports host-visible Linux containers, not containers inside another VM/kernel.

The extended process and recording-list binary responses are requested with `containers=1`; outerframe responses retain their original layout. Run `python3 Scripts/test_container_processes.py` to check the backend and actual JavaScript decoder. Passing an output filename exports a Linux response fixture for decoding on a development machine with Node.

## macOS container tracing

The user app supports registered Docker and Apple Container targets. The Mac
backend never traces macOS. The landing page chooses a runtime or an Apple
container; target paths are retained in HTML and outerframe navigation.

Docker uses an app-owned Linux worker with explicit tracing capabilities and
access to the VM PID namespace. Only containers in Outer Shell's binary registry
are eligible, and expired registry snapshots fail closed. No Docker socket is
mounted in the worker. It starts on first use and stops with the Mac backend.

Apple Container runs the app's own Linux helper inside the selected container.
The helper stays alive while the backend uses it and exits when its stdin closes.
Requests and responses use the existing binary app APIs in offset-based TRPC
frames over `container exec --interactive`; there is no JSON helper protocol.
The registry, rather than CLI container listings, supplies targets.

Build and install with `./app deploy --local`. Xcode and either Docker or Apple
Container are needed to build the Linux helper. Set
`OUTER_BUILD_CONTAINER_RUNTIME=container|docker` to choose the builder. The app
packages its helper under `Contents/Resources/helpers`, and Outer Shell's
container bootstrap includes it in new base images. Existing images need their
helper installed at `/usr/local/bin/outer-profile-helper` and rebuilt.
Docker worker images are built during installation when Docker is available, or
on first Docker use otherwise.

Profile also requires `perf` in the target image and permission to sample its
processes. In-container sampling omits namespace events so Apple Container's
default capabilities suffice with its standard kernel settings. A live recording has been
verified against Apple Container 1.1.0's standard Linux 6.18.15 kernel. Apple
recordings live in `/root/.local/state/outer-profile-helper`; mount that directory
as persistent storage to retain recordings across rebuilds. Docker recordings
remain in the Mac app's private state directory.

The runtime contract reserves `wslc` separately from WSL distributions (`wsl`).
Windows process spawning and live tracing remain to be implemented and tested on
Windows; the Mac implementation is not a Windows app.

Run `python3 Scripts/test_macos_container_app.py` after installation to verify
Docker APIs, host exclusion, HTML and favicon. The portable frame codec test is
`cc -std=gnu17 Scripts/test_tracing_stream.c -o /tmp/test-stream && /tmp/test-stream`.
