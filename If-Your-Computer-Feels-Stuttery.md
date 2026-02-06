**Overview**
This guide covers UI stutter that coincides with high CPU usage in `colorsyncd` or `colorsync.displayservices` after repeated virtual display sessions.

**Symptoms**
1. Scrolling, window dragging, or animations feel stuttery across the system.
2. `colorsyncd` or `colorsync.displayservices` shows sustained CPU usage in `top`.

**Fix Commands**
Run the block below in Terminal. It moves Mirage display profiles to a backup folder, resets the ColorSync device cache, and restarts the ColorSync services.

```bash
ts=$(date +%Y%m%d-%H%M%S)

# System-level display profiles (requires sudo)
SYS_SRC="/Library/ColorSync/Profiles/Displays"
SYS_DST="/Library/ColorSync/Profiles/MirageBackup-$ts"
sudo mkdir -p "$SYS_DST"
sudo find "$SYS_SRC" -maxdepth 1 -type f -name 'Mirage Shared Display*' -exec mv -n {} "$SYS_DST/" \;

# User-level profiles (no sudo)
USER_SRC="$HOME/Library/ColorSync/Profiles"
USER_DST="$HOME/Library/ColorSync/Profiles/MirageBackup-$ts"
mkdir -p "$USER_DST"
find "$USER_SRC" -maxdepth 1 -type f -name 'Mirage*' -exec mv -n {} "$USER_DST/" \;

# ColorSync device cache reset (requires sudo)
CACHE_DST="/Library/Caches/ColorSync/Backup-$ts"
sudo mkdir -p "$CACHE_DST"
sudo mv /Library/Caches/ColorSync/com.apple.colorsync.devices "$CACHE_DST/" 2>/dev/null || true
sudo mv /Library/Caches/ColorSync/Profiles "$CACHE_DST/" 2>/dev/null || true

# Restart ColorSync services
sudo killall colorsyncd colorsync.displayservices
```

**Verification**
Use these commands to confirm the services settle down and the Mirage profile count stays low.

```bash
top -l 2 -o cpu -n 10 -stats pid,command,cpu,mem,time
ls /Library/ColorSync/Profiles/Displays | grep -c 'Mirage Shared Display'
```

**Notes**
This cleanup is most relevant on systems that have used builds that create new virtual display identities per session.
