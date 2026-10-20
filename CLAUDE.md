# Ration

Scars and invariants only. Anything a grep or `--help` can tell you doesn't go here.

## Invariants

- `swift test` and `bash scripts/build.sh` must pass. Logic that can be tested without the
  system lives in `RationCore`, with tests. AppKit and system calls stay in `Ration`.
- No third-party dependencies.
- Release after merging a PR that changes the shipped app, without waiting to be asked. Follow
  `.claude/skills/release/SKILL.md`. Pushing a `v*` tag publishes a release, updates the
  Homebrew cask, and installed copies with automatic updates on install it within a day.
- The bundle identifier `io.github.xinding33.ration` never changes. Settings, the login item
  and the cask all hang off it.
- The repo is public. Keep account emails, tokens, machine names and personal config out of
  commits, logs pasted into docs, and PR text.

## Hazards

- Restart as a new process, never with `execv`. macOS 27 won't give the same process a menu
  bar item twice (#3).
- Releases build with the macOS 26 SDK. Code under `#if compiler(>=6.4)` is left out of shipped
  builds without warning (#7).
