#!/bin/sh
# A Roost script module. Roost runs every executable in ~/.config/roost/modules
# every 30 seconds and turns the JSON it prints into a submenu.
#
#   cp examples/modules/this-mac.sh ~/.config/roost/modules/ && chmod +x ~/.config/roost/modules/this-mac.sh
#
# Keys: title, badge ("3" or {"text": "3", "level": "info|warn|alert"}), items.
# Each item: title, and optionally run (a shell command, or an argv array),
# open (a URL or a path), items (a submenu), disabled, checked, tooltip.

up=$(uptime | sed -E 's/.*up +([^,]+),.*/\1/')
free=$(df -H / | awk 'NR==2 {print $4}')
used=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')

# Badge the menu bar when the startup disk is nearly full.
badge='null'
if [ "$used" -ge 90 ]; then
  badge="{\"text\": \"disk ${used}%\", \"level\": \"warn\"}"
fi

cat <<JSON
{
  "title": "This Mac",
  "badge": $badge,
  "items": [
    {"title": "Up $up"},
    {"title": "$free free on the startup disk"},
    {"title": "Activity Monitor", "open": "/System/Applications/Utilities/Activity Monitor.app"},
    {"title": "Copy uptime", "run": "uptime | pbcopy"}
  ]
}
JSON
