#!/bin/bash
# Removes Hush completely.
set -euo pipefail
pkill -x Hush 2>/dev/null || true
rm -rf /Applications/Hush.app
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Hush.driver
sudo killall -9 coreaudiod 2>/dev/null || true
echo "Hush removed."
