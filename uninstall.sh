#!/usr/bin/env bash
set -uo pipefail

SUPPORT="/Library/Application Support/Anvil"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo."
  exit 1
fi

# Refuse mid-session. This is friction, not security: you are root and --force
# overrides it. It exists so removing Anvil is never something you do without
# noticing you are doing it.
if [[ -f "$SUPPORT/session.json" && $FORCE -eq 0 ]]; then
  ENDS=$(/usr/bin/python3 -c "import json;print(json.load(open('$SUPPORT/session.json'))['endsAt'])" 2>/dev/null || echo "")
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ -n "$ENDS" && "$ENDS" > "$NOW" ]]; then
    echo "A session is active until $ENDS."
    echo
    echo "That is the whole point of this tool. If you are certain:"
    echo "    sudo ./uninstall.sh --force"
    exit 1
  fi
fi

# Watchdog first. It re-bootstraps anvild once a second and rewrites the plist
# while doing it, so stopping anvild first leaves a window where the watchdog
# brings it straight back and recreates the file the next line deletes.
echo "==> Stopping daemons"
launchctl bootout system/com.cjverma.anvil-watchdog 2>/dev/null || true
sleep 1
launchctl bootout system/com.cjverma.anvild 2>/dev/null || true
sleep 1
# Anything that survived the bootout, including an orphan resurrected mid-teardown.
killall -9 anvild anvil-watchdog 2>/dev/null || true

echo "==> Removing launchd jobs"
rm -f /Library/LaunchDaemons/com.cjverma.anvild.plist
rm -f /Library/LaunchDaemons/com.cjverma.anvil-watchdog.plist
rm -f /var/run/anvil.sock

echo "==> Cleaning /etc/hosts"
if grep -q "^# >>> anvil" /etc/hosts 2>/dev/null; then
  /usr/bin/python3 - <<'PY'
path = "/etc/hosts"
with open(path) as handle:
    lines = handle.readlines()
kept, inside = [], False
for line in lines:
    stripped = line.strip()
    if stripped == "# >>> anvil":
        inside = True
        continue
    if stripped == "# <<< anvil":
        inside = False
        continue
    if not inside:
        kept.append(line)
with open(path, "w") as handle:
    handle.writelines(kept)
PY
  dscacheutil -flushcache
  killall -HUP mDNSResponder 2>/dev/null || true
  echo "    removed the managed hosts section"
fi

echo "==> Restoring pf"
pfctl -a anvil -t anvil_blocked -T flush 2>/dev/null || true
pfctl -a anvil -F rules 2>/dev/null || true
if [[ -f "$SUPPORT/pf.conf.orig" ]]; then
  cp "$SUPPORT/pf.conf.orig" /etc/pf.conf
  echo "    restored /etc/pf.conf from backup"
elif grep -q "^# >>> anvil" /etc/pf.conf 2>/dev/null; then
  /usr/bin/python3 - <<'PY'
path = "/etc/pf.conf"
with open(path) as handle:
    lines = handle.readlines()
kept, inside = [], False
for line in lines:
    stripped = line.strip()
    if stripped == "# >>> anvil":
        inside = True
        continue
    if stripped == "# <<< anvil":
        inside = False
        continue
    if not inside:
        kept.append(line)
with open(path, "w") as handle:
    handle.writelines(kept)
PY
  echo "    stripped the anvil anchor from /etc/pf.conf"
fi
rm -f /etc/pf.anchors/anvil
pfctl -f /etc/pf.conf 2>/dev/null || true
# Only switch pf off if Anvil was the one that switched it on.
if [[ -f "$SUPPORT/pf-was-off" ]]; then
  pfctl -d 2>/dev/null || true
  echo "    disabled pf (Anvil had enabled it)"
fi

echo "==> Restoring browser policies"
restore_policy() {
  local target="$1"
  local slot="$SUPPORT/policy-backups/${target//\//_}"
  if [[ -f "$slot" ]]; then
    cp "$slot" "$target"
    echo "    restored $target"
  elif [[ -f "$slot.absent" ]]; then
    rm -f "$target"
    echo "    removed $target (did not exist before Anvil)"
  fi
}
for plist in com.google.Chrome com.brave.Browser com.microsoft.Edge com.vivaldi.Vivaldi; do
  restore_policy "/Library/Managed Preferences/$plist.plist"
done
restore_policy "/Applications/Firefox.app/Contents/Resources/distribution/policies.json"

echo "==> Removing binaries"
rm -rf /usr/local/anvil

echo
echo "Anvil daemons removed. $SUPPORT is preserved for inspection;"
echo "delete it with: sudo rm -rf \"$SUPPORT\""
