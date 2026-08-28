# Isolation contract — read before touching anything

This repository is the deployed Python implementation of `paseo-monitor`.
The shell implementation remains beside it as the rollback entrypoint.

## The hazard this repo exists to remove

`~/paseo-monitor` is **live production**. `~/.local/bin/paseo-monitor` is a
symlink into its `bin/`, and the launchd job `com.paseo-monitor.sweep` executes
that file **every 60 seconds** against real watches on Cannon and Polaris.
Editing it means hot-patching a running production binary: a mid-edit syntax
error is executed by the sweeper before anyone notices.

That is why the port happens here.

## Rules

1. **Use the editing launch check before repository edits.** The launchd
   sweeper runs this checkout every 60 seconds against real watches.
2. **Run `install.sh` only for an intentional deployment change.** It updates
   the pinned launcher and managed launchd plist.
3. **Never write to the real `~/.paseo-monitor` during tests.** It holds live
   production watches. Every test proof begins with:
   `export PASEO_MONITOR_HOME="$(mktemp -d)"`
4. **Never run `rm --all`, `reap`, or `poke` against the default home.** A prior
   lane destroyed a user's preserved evidence exactly that way.
5. **Never `launchctl` anything.** The production sweeper is not yours.

## Layout

- `bin/paseo-monitor` — deployed Python executable used by the launcher.
- `bin/paseo-monitor.sh` — retained shell rollback executable.
- `reference/paseo-monitor.sh` — pristine shell implementation, frozen. Diff
  against it; never edit it.
- `tests/` — the 30-test suite, copied verbatim. **This suite is the asset.**
  It encodes behaviour learned from real production incidents. A port that
  breaks a test has lost a bug fix, not failed a formality.

## Definition of a good port

Same CLI contract, same on-disk state layout, same report envelope, same exit
codes, same error strings. The spec file is a persistence format and live
watches must survive the cutover without re-registration.
