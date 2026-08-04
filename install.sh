#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Anvil.app"
DEST="/usr/local/anvil"
SUPPORT="/Library/Application Support/Anvil"

if [[ ! -d "$APP" ]]; then
  echo "Run make bundle first."
  exit 1
fi

install -d -m 0755 "$DEST"
install -d -m 0700 "$SUPPORT"
install -m 0755 "$APP/Contents/MacOS/anvild" "$DEST/anvild"
install -m 0755 "$APP/Contents/MacOS/anvil-watchdog" "$DEST/anvil-watchdog"

cat > /Library/LaunchDaemons/com.cjverma.anvild.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.cjverma.anvild</string>
  <key>ProgramArguments</key><array><string>$DEST/anvild</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Library/Logs/com.cjverma.anvild.log</string>
  <key>StandardErrorPath</key><string>/Library/Logs/com.cjverma.anvild.err</string>
</dict>
</plist>
PLIST

cat > /Library/LaunchDaemons/com.cjverma.anvil-watchdog.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.cjverma.anvil-watchdog</string>
  <key>ProgramArguments</key><array><string>$DEST/anvil-watchdog</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Library/Logs/com.cjverma.anvil-watchdog.log</string>
  <key>StandardErrorPath</key><string>/Library/Logs/com.cjverma.anvil-watchdog.err</string>
</dict>
</plist>
PLIST

chown root:wheel /Library/LaunchDaemons/com.cjverma.anvild.plist /Library/LaunchDaemons/com.cjverma.anvil-watchdog.plist
chmod 0644 /Library/LaunchDaemons/com.cjverma.anvild.plist /Library/LaunchDaemons/com.cjverma.anvil-watchdog.plist

launchctl bootstrap system /Library/LaunchDaemons/com.cjverma.anvild.plist 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.cjverma.anvil-watchdog.plist 2>/dev/null || true
launchctl kickstart -k system/com.cjverma.anvild
launchctl kickstart -k system/com.cjverma.anvil-watchdog

echo "Installed Anvil daemons. Open $APP to use the menu bar app."
