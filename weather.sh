#!/usr/bin/env bash
# 🐾 PawWeather+ — auto-location weather one-liner with icons
# by Nicky Blackburn 💻 + ChatGPT (the script kitty)

# Optional: set CITY manually to override auto-location
CITY="${1:-}"

# Function to auto-detect city via IP if not provided
detect_city() {
    local ipinfo
    ipinfo=$(curl -s https://ipinfo.io/json)
    local city
    city=$(echo "$ipinfo" | grep -oP '(?<="city":")[^"]+')
    echo "$city"
}

# If no CITY passed, try to detect it
if [ -z "$CITY" ]; then
    CITY=$(detect_city)
fi

# Fallback if detection fails
if [ -z "$CITY" ]; then
    CITY="Detroit"
fi

# Fetch weather
RAW=$(curl -s "wttr.in/${CITY}?format=%C+%t" || echo "Offline")

# Parse for emoji flair
if [[ "$RAW" == *"rain"* || "$RAW" == *"Rain"* ]]; then
    ICON="🌧️"
elif [[ "$RAW" == *"snow"* || "$RAW" == *"Snow"* ]]; then
    ICON="❄️"
elif [[ "$RAW" == *"cloud"* || "$RAW" == *"Cloud"* ]]; then
    ICON="☁️"
elif [[ "$RAW" == *"sun"* || "$RAW" == *"Sunny"* ]]; then
    ICON="☀️"
elif [[ "$RAW" == *"thunder"* ]]; then
    ICON="⛈️"
else
    ICON="🌤️"
fi

# Colors
CYAN="\033[1;36m"
RESET="\033[0m"

# Output
printf "${CYAN}🐾 PawWeather+\033[0m — %s %s (%s)\n" "$ICON" "$RAW" "$CITY"
