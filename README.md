# zatt

Minimal macOS CLI for controlling MacBook battery charging over the Apple SMC.

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

`zatt debug` prints an interpreted charging diagnostic view for local testing.
`zatt raw-status` dumps the raw IOPS, `AppleSmartBattery`, and SMC fields that
back the charging state.
`zatt watch` refreshes the real battery charging state every second so you do
not need to wait for the macOS menu bar icon to catch up.

Write-command options:

- `--wait`: keep polling until the observed battery current settles or the wait
  timeout is reached

## Build

```bash
zig build
zig build test
zig build release
```

`zig build release` produces:

- `zig-out/bin/zatt`
- `zig-out/zatt-macos-arm64.tar.gz`
