#!/bin/bash
# Reboot-only actions go here
/usr/bin/logger -t pupOS "🐶 Reboot script starting… $(date)"
# Example: ASCII bark in the journal
if command -v figlet >/dev/null 2>&1; then
  figlet "Bye for now, Pup!" | /usr/bin/logger -t pupOS
fi
# your commands...
/usr/bin/logger -t pupOS "🐶 Reboot script done."

