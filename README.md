# zatt

Minimal macOS CLI for controlling MacBook battery charging over the Apple SMC.

`zatt` exists for a specific gap in macOS: the system shows battery health and
charge state, but it does not give you a simple built-in way to tell the SMC to:

- stop charging while the charger is connected
- resume charging again later
- apply a charge limit from the command line
- verify the real battery current instead of trusting the menu bar icon

This is useful if you want to keep a MacBook plugged in for long periods without
holding the battery at 100% all the time, or if you want a lightweight way to
script charge control without running a full background app.

`zatt` talks directly to the Apple SMC and battery power-source APIs. It is a
small single-binary CLI written in Zig with no external runtime dependencies.

## What It Solves

macOS can be confusing when you are trying to manage charging manually:

- the menu bar battery icon can lag behind the real battery state
- a Mac can be on AC power without actually charging the battery
- the system UI does not expose the underlying SMC charging inhibit toggle
- charge-limit behavior is hard to script from shell tools or automation

`zatt` addresses that by giving you:

- direct SMC write commands for charging enable/disable and charge limits
- read-only status output that combines battery APIs and SMC state
- a live `watch` mode so you can see real charging current as it changes
- a `--wait` option for write commands so the CLI can observe whether charging
  has actually settled after the write

## How To Read The Output

The most important distinction in `zatt` is between:

- external power is connected
- battery current is actually flowing into the pack

Those are not always the same thing. A MacBook can be plugged in and powered by
the charger while the battery is not charging at all.

For that reason, `zatt` emphasizes:

- `Actual charging`
- `Charge current`
- `SMC inhibit`

instead of relying on the macOS menu bar icon alone.

If the menu bar says "charging" but `zatt` shows `Actual charging: no` and
`Charge current: 0 mA`, the battery is not actively taking charge at that
moment. The menu bar can lag by 1-2 minutes after a real state change.

## Install

```bash
brew tap maximbilan/zatt https://github.com/maximbilan/zatt
brew install maximbilan/zatt/zatt
```

Homebrew's `brew install user/repo/formula` shorthand only works when the GitHub
repository is named `homebrew-<repo>`. Because this project lives in
`maximbilan/zatt`, the explicit `brew tap ... <URL>` form is required.

## Usage

```bash
zatt status
zatt watch
zatt debug
zatt raw-status
sudo zatt disable
sudo zatt disable --wait
sudo zatt enable
sudo zatt enable --wait
sudo zatt limit 80
sudo zatt limit reset
```

Typical flow:

```bash
zatt status
sudo zatt disable --wait
zatt watch
sudo zatt enable --wait
sudo zatt limit 80
```

`zatt debug` prints an interpreted charging diagnostic view for local testing.
`zatt raw-status` dumps the raw IOPS, `AppleSmartBattery`, and SMC fields that
back the charging state.
`zatt watch` refreshes the real battery charging state every second so you do
not need to wait for the macOS menu bar icon to catch up.

Write-command options:

- `--wait`: keep polling until the observed battery current settles or the wait
  timeout is reached

## Notes

- `status`, `watch`, `debug`, and `raw-status` do not require `sudo`
- write commands require `sudo` because they talk to privileged SMC interfaces
- this project targets Apple Silicon Macs on macOS 13+
- `limit` only accepts `80`, `100`, or `reset` on Apple Silicon
- direct `BCLM`/`CHWA` charge-limit writes are blocked by macOS 15+ entitlement enforcement
- battery health text is shown as reported by macOS, for example `Normal`,
  `Check Battery`, or similar platform-specific values

## Build

```bash
zig build
zig build test
zig build release
```

`zig build release` produces:

- `zig-out/bin/zatt`
- `zig-out/zatt-macos-arm64.tar.gz`
