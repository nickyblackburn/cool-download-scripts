#!/usr/bin/env bash
# pup-power.sh — cute power helper for i3
# Usage: pup-power.sh [poweroff|reboot|suspend] [--now] [--no-color]

set -euo pipefail

ACTION="${1:-poweroff}"
IMMEDIATE="no"
COLOR="yes"

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --now) IMMEDIATE="yes" ;;
    --no-color) COLOR="no" ;;
  esac
done

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found. Are you on systemd?"; exit 1
fi

# Optional helpers (nice but not required)
HAVE_FIGLET="no"; command -v figlet >/dev/null && HAVE_FIGLET="yes"
HAVE_TOILET="no"; command -v toilet >/dev/null && HAVE_TOILET="yes"
HAVE_LOLCAT="no"; command -v lolcat  >/dev/null && HAVE_LOLCAT="yes"

# Colors
if [[ "$COLOR" == "yes" ]]; then
  RED='\033[1;31m'; GRN='\033[1;32m'; CYA='\033[1;36m'; MAG='\033[1;35m'; YEL='\033[1;33m'; NC='\033[0m'
else
  RED=''; GRN=''; CYA=''; MAG=''; YEL=''; NC=''
fi

# Config paths
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pup-power"
QUOTES="$CONF_DIR/quotes.txt"
mkdir -p "$CONF_DIR"

# Default quotes if user has none
if [[ ! -s "$QUOTES" ]]; then
  cat >"$QUOTES" <<'EOF'
drink water, babygirl. mommy’s proud of you. 💜
you did enough today. rest is productive.
small steps still count as steps.
future-you says "thank you" for shutting down clean.
breathe in 4… hold 1… out 6. good pup.
EOF
fi

# Pick a random quote
if command -v shuf >/dev/null 2>&1; then
  QUOTE="$(shuf -n1 "$QUOTES")"
else
  QUOTE="$(awk 'BEGIN{srand()} {a[NR]=$0} END{print a[int(rand()*NR)+1]}' "$QUOTES")"
fi

# ASCII banner
print_banner () {
  local text="Goodnight, pup"
  if [[ "$HAVE_TOILET" == "yes" ]]; then
    toilet -f big -F border "$text"
  elif [[ "$HAVE_FIGLET" == "yes" ]]; then
    figlet "$text"
  else
    cat <<'ART'
  ____              _       _       _     _     _
 / ___|  ___   ___ | |_ ___| | __ _| |__ | |__ (_)_ __
 \___ \ / _ \ / _ \| __/ __| |/ _` | '_ \| '_ \| | '_ \
  ___) | (_) | (_) | || (__| | (_| | |_) | |_) | | | | |
 |____/ \___/ \___/ \__\___|_|\__,_|_.__/|_.__/|_|_| |_|
ART
  fi
}

# Cute icon for the action
icon_for () {
  case "$1" in
    poweroff) echo "⏻" ;;
    reboot)   echo "" ;;
    suspend)  echo "" ;;
    *)        echo "❓" ;;
  esac
}

# Countdown (cancel with Ctrl+C)
countdown () {
  local secs="$1"
  echo
  echo -e "${YEL}press Ctrl+C to cancel${NC}"
  trap 'echo -e "\n${RED}Canceled. Staying awake.🐶${NC}"; exit 130' INT
  while [ "$secs" -gt 0 ]; do
    printf "\r${CYA}… %ds …${NC}" "$secs"
    sleep 1
    : $((secs--))
  done
  echo
}

clear
print_banner | { [[ "$HAVE_LOLCAT" == "yes" && "$COLOR" == "yes" ]] && lolcat || cat; }

ACTICON="$(icon_for "$ACTION")"
echo -e "\n${MAG}$ACTICON  Action:${NC} $ACTION"
echo -e "${GRN}message:${NC} ${QUOTE}\n"

if [[ "$IMMEDIATE" == "no" ]]; then
  countdown 5
fi

# Do the thing
case "$ACTION" in
  poweroff) exec systemctl poweroff ;;
  reboot)   exec systemctl reboot ;;
  suspend)  exec systemctl suspend ;;
  *) echo "Unknown action: $ACTION"; exit 2 ;;
esac

