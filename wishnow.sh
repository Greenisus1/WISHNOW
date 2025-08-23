#!/usr/bin/env bash
# WISHNOW — single-file, offline-first, no-AI
# Author: Liam Winnie

set +e

# ------------------------- Paths -------------------------
CONFIG_DIR="$HOME/.wishnow"
WISHES_FILE="$CONFIG_DIR/wishes.txt"
NAME_FILE="$CONFIG_DIR/name.txt"
HISTORY_FILE="$CONFIG_DIR/history.log"
mkdir -p "$CONFIG_DIR"
touch "$WISHES_FILE" "$NAME_FILE" "$HISTORY_FILE"

# ------------------------- Helpers -----------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
safe_tmp() { mktemp "${TMPDIR:-/tmp}/wishnow.XXXXXXXX"; }
timestamp() { date '+%F %T'; }
log_event() { printf "[%s] %s\n" "$(timestamp)" "$1" >>"$HISTORY_FILE"; }

HAVE_WHIPTAIL=0
if have_cmd whiptail; then HAVE_WHIPTAIL=1; fi

# ------------------------- UI Layer ----------------------
ui_msg() {
  local msg="$1"
  if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
    whiptail --msgbox "$msg" 12 70
  else
    printf "\n%s\n\n" "$msg"
    read -r -p "Press Enter to continue... " _
  fi
}

ui_yesno() {
  local msg="$1"
  if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
    whiptail --yesno "$msg" 10 70
    return $?
  else
    read -r -p "$msg [y/N]: " ans
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# Echoes input to stdout, returns 0 on success, 1 on cancel/empty
ui_input() {
  local prompt="$1" default="${2:-}"
  if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
    local out
    out=$(whiptail --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3) || return 1
    [ -z "$out" ] && return 1
    printf "%s" "$out"
    return 0
  else
    if [ -n "$default" ]; then
      read -r -p "$prompt [$default]: " out
      out="${out:-$default}"
    else
      read -r -p "$prompt: " out
    fi
    [ -z "$out" ] && return 1
    printf "%s" "$out"
    return 0
  fi
}

# ui_menu "title" "prompt" "key1" "desc1" "key2" "desc2" ...
# Echoes selected key to stdout, returns 0 on success.
ui_menu() {
  local title="$1"; shift
  local prompt="$1"; shift
  if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
    whiptail --title "$title" --menu "$prompt" 20 70 10 "$@" 3>&1 1>&2 2>&3
    return $?
  else
    printf "\n== %s ==\n%s\n" "$title" "$prompt"
    local keys=() descs=()
    while [ "$#" -gt 0 ]; do
      keys+=("$1"); shift
      descs+=("$1"); shift
    done
    for idx in "${!keys[@]}"; do
      printf "  %2d) %s — %s\n" "$((idx+1))" "${keys[$idx]}" "${descs[$idx]}"
    done
    read -r -p "Choose number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#keys[@]}" ]; then
      echo "${keys[$((n-1))]}"
      return 0
    fi
    return 1
  fi
}

# ui_checklist "title" "prompt" "key" "desc" OFF/ON ...
# Echoes selected keys space-separated to stdout, returns 0 on success.
ui_checklist() {
  local title="$1"; shift
  local prompt="$1"; shift
  if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
    whiptail --title "$title" --checklist "$prompt" 20 70 12 "$@" 3>&1 1>&2 2>&3
    return $?
  else
    printf "\n== %s ==\n%s\n" "$title" "$prompt"
    local keys=() descs=()
    while [ "$#" -gt 0 ]; do
      keys+=("$1"); shift
      descs+=("$1"); shift
      shift || true
    done
    for idx in "${!keys[@]}"; do
      printf "  %2d) %s — %s\n" "$((idx+1))" "${keys[$idx]}" "${descs[$idx]}"
    done
    read -r -p "Enter numbers separated by commas (e.g., 1,3,5): " line
    line="${line// /}"
    IFS=',' read -r -a nums <<<"$line"
    local out=()
    for n in "${nums[@]}"; do
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#keys[@]}" ]; then
        out+=("${keys[$((n-1))]}")
      fi
    done
    echo "${out[*]}"
    return 0
  fi
}

ui_textbox_file() {
  local file="$1"
  if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
    whiptail --textbox "$file" 22 80
  else
    printf "\n----- %s -----\n" "$file"
    cat "$file"
    printf "\n----------------------\n"
    read -r -p "Press Enter to continue... " _
  fi
}

ui_textbox_str() {
  local content="$1"
  if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
    local tmp; tmp="$(safe_tmp)"; printf "%s\n" "$content" >"$tmp"
    whiptail --textbox "$tmp" 22 80
    rm -f "$tmp"
  else
    printf "\n%s\n" "$content"
    read -r -p "Press Enter to continue... " _
  fi
}

# ------------------------- Name/Profile ------------------
get_name() { cat "$NAME_FILE"; }
set_name() { printf "%s" "$1" >"$NAME_FILE"; }

onboard_if_needed() {
  local nm; nm="$(get_name)"
  if [ -z "$nm" ]; then
    nm="$(ui_input "Welcome to WISHNOW! What's your name?" "")" || nm="Friend"
    set_name "$nm"
    log_event "Initialized profile for $nm"
  fi
}

# ------------------------- Wish Ops ----------------------
add_wish() {
  local wish
  wish="$(ui_input 'Enter your new wish:' '')" || return
  [ -z "$wish" ] && return
  printf "%s\n" "$wish" >>"$WISHES_FILE"
  log_event "Added wish: $wish"
}

view_wishes() {
  if [ ! -s "$WISHES_FILE" ]; then
    ui_msg "No wishes yet!"
    return
  fi
  ui_textbox_file "$WISHES_FILE"
}

build_wish_choices() {
  # echoes triplets suitable for checklist/menu: "idx" "text" "OFF"
  local i=0 line
  while IFS= read -r line; do
    i=$((i+1))
    printf "%s\n%s\n%s\n" "$i" "${line:-"(blank)"}" "OFF"
  done <"$WISHES_FILE"
}

delete_wishes() {
  if [ ! -s "$WISHES_FILE" ]; then
    ui_msg "No wishes to delete."
    return
  fi
  local choices=() triple
  while IFS= read -r triple; do choices+=("$triple"); done < <(build_wish_choices)
  local selected
  selected="$(ui_checklist 'Delete wishes' 'Select wishes to delete:' "${choices[@]}")" || return
  selected="${selected//\"/}"
  [ -z "$selected" ] && return
  local tmp; tmp="$(safe_tmp)"; : >"$tmp"
  local i=0 line
  while IFS= read -r line; do
    i=$((i+1))
    local skip=0
    for s in $selected; do [ "$i" = "$s" ] && skip=1 && break; done
    [ "$skip" -eq 0 ] && printf "%s\n" "$line" >>"$tmp"
  done <"$WISHES_FILE"
  mv "$tmp" "$WISHES_FILE"
  ui_msg "Selected wishes deleted."
  log_event "Deleted wishes indices: $selected"
}

edit_wish() {
  if [ ! -s "$WISHES_FILE" ]; then
    ui_msg "No wishes to edit."
    return
  fi
  local entries=() idx=0 line
  while IFS= read -r line; do
    idx=$((idx+1))
    entries+=("$idx" "${line:-"(blank)"}")
  done <"$WISHES_FILE"
  local pick
  pick="$(ui_menu 'Edit wish' 'Choose a wish to edit:' "${entries[@]}")" || return
  [ -z "$pick" ] && return
  local cur; cur="$(sed -n "${pick}p" "$WISHES_FILE")"
  local new; new="$(ui_input "Edit wish #$pick" "$cur")" || return
  local tmp; tmp="$(safe_tmp)"
  nl -ba -w1 -s$'\t' "$WISHES_FILE" | awk -v n="$pick" -v repl="$new" -F'\t' '
    NR == n {print repl; next}
    {print $2}
  ' >"$tmp"
  mv "$tmp" "$WISHES_FILE"
  ui_msg "Wish #$pick updated."
  log_event "Edited wish #$pick: '$cur' -> '$new'"
}

move_wish() {
  if [ ! -s "$WISHES_FILE" ]; then
    ui_msg "No wishes to move."
    return
  fi
  local entries=() idx=0 line
  while IFS= read -r line; do
    idx=$((idx+1))
    entries+=("$idx" "${line:-"(blank)"}")
  done <"$WISHES_FILE"
  local src dst
  src="$(ui_menu 'Move wish' 'Select wish to move:' "${entries[@]}")" || return
  [ -z "$src" ] && return
  dst="$(ui_input "Move wish #$src to position (1-$idx)" "")" || return
  if ! [[ "$dst" =~ ^[0-9]+$ ]] || [ "$dst" -lt 1 ] || [ "$dst" -gt "$idx" ]; then
    ui_msg "Invalid destination."
    return
  fi
  if [ "$src" -eq "$dst" ]; then
    ui_msg "Source and destination are the same."
    return
  fi
  local tmp; tmp="$(safe_tmp)"
  awk -v s="$src" -v d="$dst" '
    {a[NR]=$0} END{
      n=NR; t=a[s];
      for(i=s;i<n;i++) a[i]=a[i+1];
      n--;
      for(i=n;i>=d;i--) a[i+1]=a[i];
      a[d]=t; n++;
      for(i=1;i<=n;i++) print a[i];
    }
  ' "$WISHES_FILE" >"$tmp"
  mv "$tmp" "$WISHES_FILE"
  ui_msg "Moved wish #$src to position #$dst."
  log_event "Moved wish #$src to #$dst"
}

dedupe_wishes() {
  if [ ! -s "$WISHES_FILE" ]; then
    ui_msg "No wishes to deduplicate."
    return
  fi
  local tmp; tmp="$(safe_tmp)"
  awk '!seen[$0]++' "$WISHES_FILE" >"$tmp"
  mv "$tmp" "$WISHES_FILE"
  ui_msg "Removed duplicate wishes (kept first occurrences)."
  log_event "Deduplicated wishes"
}

sort_wishes() {
  if [ ! -s "$WISHES_FILE" ]; then
    ui_msg "No wishes to sort."
    return
  fi
  local mode
  mode="$(ui_menu 'Sort wishes' 'Choose sorting:' \
    "az" "Alphabetical (A→Z)" \
    "za" "Alphabetical (Z→A)" \
    "len" "By length (short→long)" \
    "revlen" "By length (long→short)")" || return
  local tmp; tmp="$(safe_tmp)"
  case "$mode" in
    az) LC_ALL=C sort "$WISHES_FILE" >"$tmp" ;;
    za) LC_ALL=C sort -r "$WISHES_FILE" >"$tmp" ;;
    len) awk '{print length, $0}' "$WISHES_FILE" | sort -n | cut -d" " -f2- >"$tmp" ;;
    revlen) awk '{print length, $0}' "$WISHES_FILE" | sort -nr | cut -d" " -f2- >"$tmp" ;;
    *) rm -f "$tmp"; return ;;
  esac
  mv "$tmp" "$WISHES_FILE"
  ui_msg "Wishes sorted: $mode"
  log_event "Sorted wishes by $mode"
}

search_wishes() {
  if [ ! -s "$WISHES_FILE" ]; then
    ui_msg "No wishes to search."
    return
  fi
  local q; q="$(ui_input 'Search query (case-insensitive):' '')" || return
  local tmp; tmp="$(safe_tmp)"
  nl -ba -w2 -s'. ' "$WISHES_FILE" | grep -i --color=never -n -e "$q" | sed 's/^[0-9]\+://g' >"$tmp"
  if [ ! -s "$tmp" ]; then
    printf "No matches for: %s\n" "$q" >"$tmp"
  else
    sed -i "1i Matches for \"$q\":\n" "$tmp"
  fi
  ui_textbox_file "$tmp"
  rm -f "$tmp"
}

export_wishes() {
  local path; path="$(ui_input 'Export to path (will overwrite):' "$HOME/wishes_export.txt")" || return
  cp -f "$WISHES_FILE" "$path"
  ui_msg "Exported wishes to: $path"
  log_event "Exported wishes to $path"
}

import_wishes() {
  local path; path="$(ui_input 'Import from path:' '')" || return
  if [ ! -f "$path" ]; then
    ui_msg "File not found: $path"
    return
  fi
  if ui_yesno "Append to current wishes? (No = replace)"; then
    cat "$path" >>"$WISHES_FILE"
    ui_msg "Appended wishes from: $path"
    log_event "Imported (append) from $path"
  else
    cp -f "$path" "$WISHES_FILE"
    ui_msg "Replaced wishes with contents of: $path"
    log_event "Imported (replace) from $path"
  fi
}

clear_all_data() {
  if ui_yesno "This will clear ALL wishes and history. Continue?"; then
    : >"$WISHES_FILE"
    : >"$HISTORY_FILE"
    ui_msg "All wishes and history cleared."
    log_event "Cleared all data"
  fi
}

# ------------------------- History -----------------------
view_history() {
  if [ ! -s "$HISTORY_FILE" ]; then
    ui_msg "History is empty."
    return
  fi
  ui_textbox_file "$HISTORY_FILE"
}

# ------------------------- Settings ----------------------
settings_menu() {
  local nm; nm="$(get_name)"; [ -z "$nm" ] && nm="Friend"
  while true; do
    local choice
    choice="$(ui_menu 'Settings' "Current name: $nm" \
      "name" "Change name" \
      "history" "View history" \
      "clear" "Clear all data" \
      "back" "Back to main")" || return
    case "$choice" in
      name)
        local new; new="$(ui_input 'Enter your name:' "$nm")" || continue
        set_name "$new"; nm="$new"
        ui_msg "Name updated to: $nm"
        log_event "Changed name to $nm"
        ;;
      history) view_history ;;
      clear) clear_all_data ;;
      back) break ;;
      *) : ;;
    esac
  done
}

# ------------------------- Main Menu ---------------------
main_menu() {
  local nm; nm="$(get_name)"; [ -z "$nm" ] && nm="Friend"
  while true; do
    local choice
    choice="$(ui_menu "WISHNOW — Hello, $nm" 'Choose an option:' \
      "add" "Add a wish" \
      "view" "View wishes" \
      "edit" "Edit a wish" \
      "move" "Reorder a wish" \
      "delete" "Delete wishes" \
      "dedupe" "Remove duplicates" \
      "sort" "Sort wishes" \
      "search" "Search wishes" \
      "export" "Export wishes" \
      "import" "Import wishes" \
      "settings" "Settings" \
      "exit" "Exit")" || break
    case "$choice" in
      add) add_wish ;;
      view) view_wishes ;;
      edit) edit_wish ;;
      move) move_wish ;;
      delete) delete_wishes ;;
      dedupe) dedupe_wishes ;;
      sort) sort_wishes ;;
      search) search_wishes ;;
      export) export_wishes ;;
      import) import_wishes ;;
      settings) settings_menu ;;
      exit) break ;;
      *) : ;;
    esac
  done
}

# ------------------------- Launch ------------------------
onboard_if_needed
main_menu
nm="$(get_name)"
ui_msg "Thanks for using WISHNOW, ${nm:-Friend}! See you next time."
exit 0
