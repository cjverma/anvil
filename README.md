# Anvil

Anvil is a macOS 13+ app and website blocker with no daemon-level cancel or shorten command. Blocks survive quitting the menu-bar app, force-quit, app deletion, hosts edits, DNS-over-HTTPS, QUIC, bundle renaming, and reboot. On an admin Mac, Safe Mode remains the intentional recovery path.

## Build

```sh
make test
make build
make bundle
```

## Install

```sh
sudo ./install.sh
open Anvil.app
```

Before a real session, run:

```sh
sudo .build/release/anvild --dry-run
sudo .build/release/anvild --test-mode
```

The dry run prints what would be killed or written without changing the system. Test mode starts a two-minute throwaway session with escape tools exempt.

## Uninstall

```sh
sudo ./uninstall.sh
```

## Recovery

No third-party app can be unbypassable on a Mac where you are an admin. Safe Mode disables third-party LaunchDaemons by design and is Anvil's documented escape if a bug blocks too much.
