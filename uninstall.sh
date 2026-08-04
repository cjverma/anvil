#!/usr/bin/env bash
set -euo pipefail

launchctl bootout system/com.cjverma.anvild 2>/dev/null || true
launchctl bootout system/com.cjverma.anvil-watchdog 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.cjverma.anvild.plist
rm -f /Library/LaunchDaemons/com.cjverma.anvil-watchdog.plist
rm -f /var/run/anvil.sock
rm -rf /usr/local/anvil
echo "Anvil daemons removed. /Library/Application Support/Anvil is preserved for inspection."
