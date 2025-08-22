#!/usr/bin/env bash
# =========================================
# WISHNOW — single-file Pi app with LemonAI
# - Whiptail UI (no heavy deps)
# - Persistent config & memory (~/.wishnow)
# - Personality quiz
# - LemonAI ideas (offline rules, learns from feedback)
# - "Like" adds idea to wishes automatically
# - Amazon search by opening a browser link (no API keys)
# - Self-update from GitHub (optional)
# =========================================

set -euo pipefail

APP_NAME="WISHNOW"
APP_VERSION="1.0.0"
AUTHOR="Liam & Copilot"
GITHUB_RAW_URL="https://raw.githubusercontent.com/Greenisus1/WISHNOW/main/wishnow.sh"

# Paths
CONFIG_DIR="${HOME}/.wishnow"
WISHES_FILE="${CONFIG_DIR}/wishes.txt"
MEMORY_FILE="${CONFIG_DIR}/lemonAI_memory.json"
SETTINGS_FILE="${CONFIG_DIR}/settings.ini"
TMP_DIR="${CONFIG_DIR}/tmp"
LOG_FILE="${CONFIG_DIR}/wishnow.log"

# Defaults
DEFAULT_AI_MODE="offline"        # offline (no network needed)
DEFAULT_AI_ENDPOINT=""           # optional (e.g., http://localhost:11434/api/generate for local Ollama) — not required
DEFAULT_AMAZON_OPEN="ask"        # ask | auto | off (open browser for Amazon search links)

# --------------- Utils -------------------

mkdir -p "$CONFIG_DIR" "$TMP_DIR"
touch "$LOG_FILE"

log() { printf "[%s] %s\n" "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

cleanup() { rm -f "$TMP_DIR"/* 2>/dev/null || true; }
trap cleanup EXIT

ensure_deps() {
  local missing=()
  for c in whiptail jq sed awk tr cut; do
    require_cmd "$c" || missing+=("$c")
  done
  # xdg-open is optional (for Amazon links)
  if ((${#missing[@]})); then
    if command -v apt >/dev/null 2>&1; then
      whiptail --yesno "Missing dependencies: ${missing[*]}\nInstall now?" 12 60 || {
        whiptail --msgbox "Cannot continue without: ${missing[*]}" 10 60
        exit 1
      }
      sudo apt update -y
      sudo apt install -y whiptail jq
    else
      whiptail --msgbox "Missing: ${missing[*]}\nPlease install them and re-run." 10 60
      exit 1
    fi
  fi
  # Suggest xdg-utils for opening links, but don't require it
  if ! require_cmd xdg-open; then
    log "Tip: Install xdg-utils to auto-open Amazon links (sudo apt install xdg-utils)."

# Simple INI
ini_get() { [ -f "$SETTINGS_FILE" ] && awk -F'=' -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SETTINGS_FILE" | tail -n1 || true; }
ini_set() {
  local key="$1" val="$2"
  touch "$SETTINGS_FILE"
  if grep -q "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*$|${key}=${val}|" "$SETTINGS_FILE"
  else
    printf "%s=%s\n" "$key" "$val" >>"$SETTINGS_FILE"
  fi
}

# JSON memory helpers
ensure_memory() {
  if [ ! -f "$MEMORY_FILE" ]; then
    cat >"$MEMORY_FILE" <<'JSON'
{
  "personality": {
    "name": "",
    "traits": [],
    "mbti": ""
  },
  "preferences": {
    "likes": [],
    "dislikes": [],
    "tag_scores": {}
  },
  "history": []
}
JSON
  fi
}

memory_set_name() {
  local name="$1" tmp="${TMP_DIR}/mem.tmp"
  jq --arg n "$name" '.personality.name = $n' "$MEMORY_FILE" >"$tmp" && mv "$tmp" "$MEMORY_FILE"
}

memory_set_traits_json() {
  local traits_json="$1" tmp="${TMP_DIR}/mem.tmp"
  jq --argjson t "$traits_json" '.personality.traits = $t' "$MEMORY_FILE" >"$tmp" && mv "$tmp" "$MEMORY_FILE"
}

append_history() {
  local msg="$1" now; now="$(date '+%F %T')"
  local tmp="${TMP_DIR}/mem.tmp"
  jq --arg d "$now" --arg m "$msg" '.history += [{date:$d, interaction:$m}]' "$MEMORY_FILE" >"$tmp" && mv "$tmp" "$MEMORY_FILE"
}

append_like() {
  local idea="$1" tmp="${TMP_DIR}/mem.tmp"
  jq --arg i "$idea" '.preferences.likes += [$i]' "$MEMORY_FILE" >"$tmp" && mv "$tmp" "$MEMORY_FILE"
}

append_dislike() {
  local idea="$1" tmp="${TMP_DIR}/mem.tmp"
  jq --arg i "$idea" '.preferences.dislikes += [$i]' "$MEMORY_FILE" >"$tmp" && mv "$tmp" "$MEMORY_FILE"
}

bump_tag() {
  local tag="$1" delta="${2:-1}" tmp="${TMP_DIR}/mem.tmp"
  jq --arg t "$tag" --argjson d "$delta" '.preferences.tag_scores[$t] = (.preferences.tag_scores[$t] // 0) + $d' "$MEMORY_FILE" >"$tmp" && mv "$tmp" "$MEMORY_FILE"
}

# --------------- First run & quiz -------------------

splash() {
  whiptail --title "$APP_NAME" --msgbox "Welcome to $APP_NAME v$APP_VERSION" 8 40
}

first_run() {
  ensure_memory
  local name
  name=$(whiptail --inputbox "Welcome to $APP_NAME!\nWhat should I call you?" 10 60 "" 3>&1 1>&2 2>&3) || name=""
  [ -z "$name" ] && name="Friend"
  ini_set "NAME" "$name"
  ini_set "AI_MODE" "$DEFAULT_AI_MODE"
  ini_set "AI_ENDPOINT" "$DEFAULT_AI_ENDPOINT"
  ini_set "AMAZON_OPEN" "$DEFAULT_AMAZON_OPEN"
  memory_set_name "$name"
  whiptail --msgbox "Nice to meet you, $name! Let's do a quick personality setup." 10 60
  personality_quiz
}

personality_quiz() {
  ensure_memory
  local choices=(
    "outdoorsy"   "Loves nature and being outside" OFF
    "creative"    "Enjoys art, writing, or making things" OFF
    "tech-savvy"  "Into coding, gadgets, and tinkering" OFF
    "social"      "Energized by people and events" OFF
    "reflective"  "Likes journaling, reading, deep dives" OFF
    "active"      "Enjoys sports and movement" OFF
    "helper"      "Likes volunteering and service" OFF
    "gamer"       "Enjoys games and playful challenges" OFF
    "maker"       "Builds, crafts, DIY projects" OFF
    "adventurous" "Likes new experiences and travel" OFF
  )
  local traits_raw
  traits_raw=$(whiptail --checklist "Pick any traits that fit you" 20 70 10 "${choices[@]}" 3>&1 1>&2 2>&3) || traits_raw=""
  # Convert space-separated quoted tokens into JSON array
  local arr=() tok
  for tok in $traits_raw; do
    tok="${tok%\"}"; tok="${tok#\"}"
    arr+=("$tok")
  done
  local json="["
  local first=1
  for t in "${arr[@]}"; do
    if [ $first -eq 1 ]; then first=0; else json+=", "; fi
    json+="\"$t\""
  done
  json+="]"
  memory_set_traits_json "$json"
  whiptail --msgbox "Thanks! LemonAI will tailor ideas to your personality." 10 60
}

# --------------- Wishes -------------------

ensure_files() {
  mkdir -p "$CONFIG_DIR" "$TMP_DIR"
  touch "$WISHES_FILE" "$SETTINGS_FILE"
  ensure_memory
}

add_wish_manual() {
  local wish
  wish=$(whiptail --inputbox "✨ What wish would you like to add?" 10 70 "" 3>&1 1>&2 2>&3) || return 0
  wish="${wish//$'\n'/ }"
  wish="${wish//$'\r'/ }"
  [ -z "$wish" ] && whiptail --msgbox "No wish added." 8 40 && return 0
  echo "$wish" >>"$WISHES_FILE"
  append_history "User added wish: $wish"
  if ask_amazon_open; then amazon_search "$wish"; fi
}

view_wishes() {
  if [ ! -s "$WISHES_FILE" ]; then
    whiptail --msgbox "No wishes yet. Add one!" 8 40
    return
  fi
  whiptail --textbox "$WISHES_FILE" 20 70
}

manage_wishes() {
  if [ ! -s "$WISHES_FILE" ]; then
    whiptail --msgbox "No wishes to manage." 8 40
    return
  fi
  local i=0 choices=()
  while IFS= read -r line; do
    i=$((i+1))
    choices+=("$i" "$line" OFF)
  done <"$WISHES_FILE"

  local sel
  sel=$(whiptail --checklist "Select wishes to delete" 20 80 12 "${choices[@]}" 3>&1 1>&2 2>&3) || return
  [ -z "$sel" ] && return

  local ids=()
  local tok
  for tok in $sel; do
    tok="${tok%\"}"; tok="${tok#\"}"
    ids+=("$tok")
  done

  local tmp="${TMP_DIR}/wishes.new"
  : >"$tmp"
  i=0
  while IFS= read -r line; do
    i=$((i+1))
    local keep=1 id
    for id in "${ids[@]}"; do
      [ "$i" = "$id" ] && { keep=0; break; }
    done
    [ $keep -eq 1 ] && echo "$line" >>"$tmp"
  done <"$WISHES_FILE"

  mv "$tmp" "$WISHES_FILE"
  whiptail --msgbox "Selected wishes deleted." 8 40
}

# --------------- Tagging & offline ideas -------------------

infer_tags() {
  local text="${1,,}"
  local tags=()
  [[ "$text" =~ (hike|trail|camp|nature|outdoor|river|park) ]] && tags+=("outdoors")
  [[ "$text" =~ (code|coding|program|pi|raspberry|script|tech|server) ]] && tags+=("tech")
  [[ "$text" =~ (art|draw|paint|write|creative|craft|music|photo) ]] && tags+=("creative")
  [[ "$text" =~ (friend|club|group|event|party|social|meetup) ]] && tags+=("social")
  [[ "$text" =~ (journal|read|book|reflect|mindful|meditate) ]] && tags+=("reflective")
  [[ "$text" =~ (run|bike|sport|workout|fitness|yoga) ]] && tags+=("active")
  [[ "$text" =~ (help|volunteer|service|donate|mentor) ]] && tags+=("helper")
  [[ "$text" =~ (game|minecraft|play|puzzle|speedrun|indie) ]] && tags+=("gamer")
  [[ "$text" =~ (build|make|diy|3d print|kit|solder|laser|cnc) ]] && tags+=("maker")
  [[ "$text" =~ (trip|travel|explore|adventure|cuisine) ]] && tags+=("adventurous")
  printf "%s\n" "${tags[@]}"
}

offline_bank() {
  case "$1" in
    outdoors)
      cat <<EOF
Plan a sunrise hike at a nearby trail
Start a backyard pollinator garden
Join a local park or river cleanup
Map a bike route you’ve never tried
Camp under the stars this month
EOF
      ;;
    tech)
      cat <<EOF
Build a Raspberry Pi weather station
Automate a daily task with a shell script
Set up a home media server on the Pi
Create a simple website for a hobby
Contribute a small fix to an open-source project
EOF
      ;;
    creative)
      cat <<EOF
Start a 7-day sketch or photo challenge
Write a one-page short story tonight
Design a custom sticker or patch
Make a playlist that tells a story
Try a new craft and gift it to a friend
EOF
      ;;
    social)
      cat <<EOF
Host a board-game night
Invite a friend for a coffee walk
Join a local meetup that matches a hobby
Write a thank-you note to a mentor
Plan a small potluck with a theme
EOF
      ;;
    reflective)
      cat <<EOF
Begin a 5-minute daily journal
Curate a reading list of 3 books
Do a weekly digital detox hour
Reflect on 3 wins from the past week
Write a letter to your future self
EOF
      ;;
    active)
      cat <<EOF
Try a new bodyweight routine
Bike to an errand instead of driving
Learn a simple yoga flow
Do a weekend 5k route with friends
Track steps for a fun weekly goal
EOF
      ;;
    helper)
      cat <<EOF
Volunteer one hour this week
Assemble a small care kit for donation
Offer free tech help to a neighbor
Organize a mini drive (books, coats, food)
Mentor someone starting in your field
EOF
      ;;
    gamer)
      cat <<EOF
Speedrun a favorite level and log your time
Try a new indie game and write a mini review
Create a custom Minecraft build challenge
Host a friendly game night tournament
Learn a new puzzle game and share tips
EOF
      ;;
    maker)
      cat <<EOF
3D print a useful household tool
Solder a simple LED kit
Upcycle something you’d toss
Make a laser-cut or CNC project plan
Build a tiny desk organizer
EOF
      ;;
    adventurous)
      cat <<EOF
Plan a day trip to a new town
Try a cuisine you’ve never had
Ride a bus line to its end and explore
Book a class you’ve always postponed
Do one thing that scares you (safely)
EOF
      ;;
  esac
}

select_top_tags() {
  # Baseline from personality + learned scores
  declare -A score=()
  local t
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
      tech-savvy) t="tech" ;;
      outdoorsy)  t="outdoors" ;;
    esac
    score["$t"]=$(( ${score["$t"]:-0} + 2 ))
  done < <(jq -r '.personality.traits[]?' "$MEMORY_FILE")

  while read -r k v; do
    [ -z "${k:-}" ] && continue
    score["$k"]=$(( ${score["$k"]:-0} + ${v:-0} ))
  done < <(jq -r '.preferences.tag_scores | to_entries[]? | "\(.key) \(.value)"' "$MEMORY_FILE")

  for base in tech outdoors creative social reflective active helper gamer maker adventurous; do
    : "${score[$base]:=0}"
  done

  for k in "${!score[@]}"; do
    printf "%s %s\n" "$k" "${score[$k]}"
  done | sort -k2,2nr | awk '{print $1}' | head -n 5
}

generate_offline_ideas() {
  local N="${1:-5}"
  local -a seen=()
  while IFS= read -r s; do [ -n "$s" ] && seen+=("$s"); done < <(jq -r '.preferences.likes[]?, .preferences.dislikes[]?' "$MEMORY_FILE")
  local -a tags=()
  while IFS= read -r tag; do [ -n "$tag" ] && tags+=("$tag"); done < <(select_top_tags)

  local out=() tag idea skip s
  for tag in "${tags[@]}"; do
    while IFS= read -r idea; do
      [ -z "$idea" ] && continue
      skip=0
      for s in "${seen[@]:-}"; do
        [[ "$idea" == "$s" ]] && { skip=1; break; }
      done
      [ $skip -eq 1 ] && continue
      out+=("$idea")
      [ "${#out[@]}" -ge "$N" ] && break 2
    done < <(offline_bank "$tag")
  done
  printf "%s\n" "${out[@]}"
}

# --------------- Amazon (no API key) -------------------

urlencode() { jq -nr --arg s "$1" '$s|@uri'; }

ask_amazon_open() {
  local mode; mode="$(ini_get AMAZON_OPEN || true)"
  case "${mode:-ask}" in
    off) return 1 ;;
    auto) return 0 ;;
    *) whiptail --yesno "Want to search Amazon for items to help with this?" 10 70 ;;
  esac
}

amazon_search() {
  local query="$1"
  local qenc; qenc="$(urlencode "$query")"
  local url="https://www.amazon.com/s?k=${qenc}"
  if require_cmd xdg-open; then
    xdg-open "$url" >/dev/null 2>&1 || true
    whiptail --msgbox "Opened Amazon search in your browser:\n\n${url}" 12 70
  else
    whiptail --msgbox "Copy this Amazon search URL:\n\n${url}\n\nTip: Install xdg-utils to auto-open." 14 70
  fi
  append_history "Opened Amazon search for: $query"
}

# --------------- LemonAI core -------------------

lemonai_ideas() {
  ensure_files
  local name; name="$(ini_get NAME || echo Friend)"
  local suggestions
  suggestions="$(generate_offline_ideas 5)"
  [ -z "$suggestions" ] && suggestions="$(generate_offline_ideas 5)"

  local idea
  while IFS= read -r idea; do
    [ -z "$idea" ] && continue
    whiptail --msgbox "💡 ${idea}" 10 70 || true

    if whiptail --yesno "Do you like this idea?" 9 60; then
      echo "$idea" >>"$WISHES_FILE"
      append_like "$idea"
      append_history "User liked idea: $idea"
      while IFS= read -r tag; do [ -n "$tag" ] && bump_tag "$tag" 2; done < <(infer_tags "$idea")
      if ask_amazon_open; then amazon_search "$idea"; fi
    else
      append_dislike "$idea"
      append_history "User disliked idea: $idea"
      while IFS= read -r tag; do [ -n "$tag" ] && bump_tag "$tag" -1; done < <(infer_tags "$idea")
    fi
  done <<<"$suggestions"

  whiptail --msgbox "That’s all for now, $name! LemonAI will keep learning from your choices." 10 60
}

# --------------- Settings & Update -------------------

settings_menu() {
  while true; do
    local ai_mode ai_endpoint amazon_open
    ai_mode="$(ini_get AI_MODE || echo "$DEFAULT_AI_MODE")"
    ai_endpoint="$(ini_get AI_ENDPOINT || echo "$DEFAULT_AI_ENDPOINT")"
    amazon_open="$(ini_get AMAZON_OPEN || echo "$DEFAULT_AMAZON_OPEN")"

    local choice
    choice=$(whiptail --title "Settings" --menu "Adjust preferences" 20 70 10 \
      "1" "AI mode: ${ai_mode} (offline recommended; no keys needed)" \
      "2" "AI endpoint: ${ai_endpoint:-<none>} (optional local server)" \
      "3" "Amazon open: ${amazon_open} (ask/auto/off)" \
      "4" "Re-run personality quiz" \
      "5" "Back" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      1)
        local new
        new=$(whiptail --title "AI mode" --menu "Choose AI mode" 12 50 3 \
          "offline" "Use offline idea engine only" \
          "online" "Use custom local endpoint (optional)" \
          "cancel" "Back" 3>&1 1>&2 2>&3) || continue
        [ "$new" = "cancel" ] || ini_set "AI_MODE" "$new"
        ;;
      2)
        local ep
        ep=$(whiptail --inputbox "Optional local endpoint (e.g., http://localhost:11434/api/generate)\nLeave blank to disable online calls." 12 70 "$ai_endpoint" 3>&1 1>&2 2>&3) || ep="$ai_endpoint"
        ini_set "AI_ENDPOINT" "$ep"
        ;;
      3)
        local mode
        mode=$(whiptail --title "Amazon open" --menu "Choose behavior" 12 60 4 \
          "ask"  "Ask every time" \
          "auto" "Always open browser" \
          "off"  "Never open automatically" \
          "cancel" "Back" 3>&1 1>&2 2>&3) || continue
        [ "$mode" = "cancel" ] || ini_set "AMAZON_OPEN" "$mode"
        ;;
      4) personality_quiz ;;
      5) break ;;
    esac
  done
}

self_update() {
  if ! require_cmd curl; then
    whiptail --msgbox "curl is required for self-update.\nInstall: sudo apt install curl" 10 60
    return
  fi
  local current_path new_file
  # Resolve running script path
  current_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  new_file="${TMP_DIR}/wishnow.new.sh"

  whiptail --infobox "Checking for updates..." 7 40
  if ! curl -fsSL "$GITHUB_RAW_URL" -o "$new_file"; then
    whiptail --msgbox "Could not fetch update." 8 40
    return
  fi

  if cmp -s "$current_path" "$new_file"; then
    whiptail --msgbox "You already have the latest version." 8 40
    rm -f "$new_file"
    return
  fi

  if cp "$new_file" "$current_path" 2>/dev/null; then
    chmod +x "$current_path"
    whiptail --msgbox "Updated successfully. Restarting..." 8 50
    exec "$current_path"
  else
    local fallback="${CONFIG_DIR}/wishnow.sh"
    cp "$new_file" "$fallback"
    chmod +x "$fallback"
    whiptail --msgbox "No permission to overwrite $current_path.\nSaved new version to:\n$fallback\nRun it manually to switch." 12 70
  fi
}

# --------------- Main menu -------------------

main_menu() {
  while true; do
    local choice
    choice=$(whiptail --title "$APP_NAME" --menu "Choose an option" 20 70 10 \
      "1" "Add a wish" \
      "2" "View wishes" \
      "3" "Manage wishes (delete)" \
      "4" "LemonAI – Ideas for me" \
      "5" "Personality setup" \
      "6" "Settings" \
      "7" "Update WISHNOW" \
      "8" "Exit" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      1) add_wish_manual ;;
      2) view_wishes ;;
      3) manage_wishes ;;
      4) lemonai_ideas ;;
      5) personality_quiz ;;
      6) settings_menu ;;
      7) self_update ;;
      8) break ;;
    esac
  done
}

# --------------- Bootstrap -------------------

ensure_deps
ensure_files

# If first run (no name in settings), start onboarding
if [ -z "$(ini_get NAME || true)" ]; then
  splash
  first_run
fi

main_menu
