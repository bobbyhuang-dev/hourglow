# Security Policy

## Supported versions

HourGlow is maintained by one person. Only the latest release receives fixes.

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Anything older | ❌ — update first |

The app checks for updates on its own by default; you can also grab the newest build from the
[releases page](https://github.com/bobbyhuang-dev/hourglow/releases/latest).

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub:
[Report a vulnerability](https://github.com/bobbyhuang-dev/hourglow/security/advisories/new).
This creates a private advisory only the maintainer can see.

If that form is unavailable to you, email **bobbyhuang.dev@gmail.com** with `HourGlow
security` in the subject line.

Please include:

- what an attacker can do, and what they need in order to do it (local user? network
  position? a file the user was tricked into opening?);
- the affected version and your macOS version;
- steps to reproduce, or a proof of concept;
- any suggested fix, if you have one in mind.

You should get a first reply within **7 days**. If a fix is warranted, the intended timeline
is a release within **30 days** of confirming the report, and a GitHub Security Advisory
published alongside it. You will be credited in the advisory unless you'd rather not be.

## What's worth reporting

The parts of HourGlow with real security surface:

- **The updater** (`Sources/App/AppUpdater.swift` and `Sources/Updater/main.swift`). It reads
  release metadata from the GitHub API, downloads a named asset, checks the asset's SHA-256
  digest, then verifies the unpacked bundle's identifier, version and full code signature
  before a helper replaces the app in place. Anything that lets an attacker get unverified
  code installed, or that turns the in-place replacement into a way to write somewhere it
  shouldn't, is in scope.
- **Wallpaper import** (`Sources/Model/SceneImport.swift`). It walks a folder the user picked,
  copies files into the config directory, and deletes the previous scene directory. Path
  traversal, deleting files outside that directory, or clobbering data through a symlink are
  in scope.
- **Writing the system wallpaper store** (`Sources/System/WallpaperWriter.swift`). It reads,
  modifies and writes `Index.plist` under the user's own Application Support directory.
  Corrupting unrelated parts of that file, or writing outside it, is in scope.
- **The config and the single-instance lock** in
  `~/Library/Application Support/HourGlow/`. Anything that lets one local user influence
  another's schedule, or that makes the lock usable to redirect a write, is in scope.

Network behaviour, for reference: HourGlow makes exactly one kind of outbound request — to
the GitHub API, to look up the latest release, and to GitHub's asset host to download it. Sun
times are computed locally; there is no telemetry, no analytics, and no other server.

## Known limitations that are not vulnerabilities

These are documented trade-offs, not bugs. Reporting them is fine, but they won't be treated
as vulnerabilities:

- **Releases are ad-hoc signed and not notarized.** There is no paid Apple Developer account
  behind this project, so macOS blocks the first launch and the README tells users how to get
  past that (`xattr -dr com.apple.quarantine`, or *Open Anyway* in System Settings). The
  signature does carry an explicit, stable designated requirement, which is what the updater
  verifies against.
- **HourGlow writes a file macOS does not document.** `Index.plist` is not a public API.
  HourGlow backs it up before every write and preserves fields it doesn't understand, but a
  future macOS release could change the format.
- **The config directory is readable and writable by the user who owns it.** That's the
  standard permission model for a per-user Application Support directory. Another process
  running as you can already change your wallpaper directly.
- **Reports produced only by an automated scanner**, with no explanation of what an attacker
  gains, will be closed.
