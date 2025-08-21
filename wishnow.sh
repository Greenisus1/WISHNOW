#!/bin/bash

# =========================
# WISHNOW - single-file app
# =========================

CONFIG_DIR="/usr/local/etc/WISHNOW/user"
NAME_FILE="$CONFIG_DIR/NAME.txt"
SETTINGS_DIR="$CONFIG_DIR/SETTINGS"
WISHES_DIR="$CONFIG_DIR/WISHES"
GENERATED_NAMES="$SETTINGS_DIR/generated-names.txt"

# Ensure storage paths exist
sudo mkdir -p "$CONFIG_DIR" "$SETTINGS_DIR" "$WISHES_DIR"
sudo touch "$GENERATED_NAMES"

# --- First run setup ---
if [ ! -f "$NAME_FILE" ]; then
    echo "HELLO USER!"
    read -p "WHAT SHOULD I CALL YOU? NAME: " nickname
    echo "NICKNAME=$nickname" | sudo tee "$NAME_FILE" >/dev/null
    echo "HELLO $nickname"
else
    nickname=$(grep -m1 "^NICKNAME=" "$NAME_FILE" | cut -d'=' -f2)
    [ -z "$nickname" ] && nickname="FRIEND"
    echo "HELLO $nickname"
fi

# --- Helpers ---
gen_id() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8; }
now_stamp() { date +"%H/%M/%S/%3N/%m/%d/%Y"; }
extract_field() { echo "$1" | sed -n "s/.*$2=\([^\\]*\).*/\1/p"; }
reload_wishes_list() {
    # keep only IDs that still have files; clean up stale lines
    if [ -f "$GENERATED_NAMES" ]; then
        tmp=$(mktemp)
        while read -r wid; do
            [ -f "$WISHES_DIR/$wid.txt" ] && echo "$wid"
        done < "$GENERATED_NAMES" > "$tmp"
        sudo mv "$tmp" "$GENERATED_NAMES"
    fi
    mapfile -t wishes_list < "$GENERATED_NAMES"
    total=${#wishes_list[@]}
}

# --- Updater ---
update_script() {
    RAW_URL="https://raw.githubusercontent.com/Greenisus1/WISHNOW/main/wishnow.sh"
    TMP_FILE=$(mktemp)
    SCRIPT_PATH="$(realpath "$0")"

    echo "Checking for updates..."
    if ! curl -fsSL "$RAW_URL" -o "$TMP_FILE"; then
        echo "Update failed: could not download from GitHub."
        rm -f "$TMP_FILE"
        return
    fi

    # Basic sanity: ensure downloaded file looks like a shell script
    if ! head -n1 "$TMP_FILE" | grep -q "#!/bin/bash"; then
        echo "Update aborted: downloaded file is not a valid script."
        rm -f "$TMP_FILE"
        return
    fi

    if cmp -s "$SCRIPT_PATH" "$TMP_FILE"; then
        echo "You already have the latest version."
        rm -f "$TMP_FILE"
        return
    fi

    echo "New version found. Applying update..."
    # Optional backup
    cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak" 2>/dev/null || sudo cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak" >/dev/null 2>&1

    if cp "$TMP_FILE" "$SCRIPT_PATH" 2>/dev/null || sudo cp "$TMP_FILE" "$SCRIPT_PATH"; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null || sudo chmod +x "$SCRIPT_PATH"
        rm -f "$TMP_FILE"
        echo "Update complete. Restarting WISHNOW..."
        sleep 1
        exec "$SCRIPT_PATH"
    else
        echo "Update failed: could not overwrite script. Check permissions."
        rm -f "$TMP_FILE"
    fi
}

# --- New wish flow ---
new_wish() {
    echo "WHAT KIND OF WISH IS THIS? (AMAZON,TEXT,OTHER)"
    read -r -p "> " wish_type
    wish_type=$(echo "$wish_type" | tr '[:lower:]' '[:upper:]')

    echo "CREATING NEW WISH..."

    if [ "$wish_type" = "AMAZON" ]; then
        echo "SELECTED : AMAZON"
        echo "WHAT IS THE AMAZON LINK?"
        read -r -p " LINK: " link
        echo " AMAZON LINK ADDED"
        echo "WHAT IS THE NAME OF THE AMAZON ITEM"
        read -r -p "ITEM-NAME: " item_name

        while true; do
            read -r -p "IS THE LINK CORRECT: $link?(Y,n) " ans
            case "$ans" in
                [Nn]*)
                    echo "WHAT IS THE CORRECT LINK?"
                    read -r -p "LINK: " link
                    ;;
                [Yy]*|"") break ;;
                *) echo "Please answer Y or n." ;;
            esac
        done

        while true; do
            read -r -p "IS THE ITEM NAME CORRECT: $item_name?(Y,n) " ans
            case "$ans" in
                [Nn]*)
                    echo "WHAT IS THE CORRECT ITEM NAME?"
                    read -r -p "ITEM-NAME: " item_name
                    ;;
                [Yy]*|"") break ;;
                *) echo "Please answer Y or n." ;;
            esac
        done

        wish_id=$(gen_id)
        echo "$wish_id" | sudo tee -a "$GENERATED_NAMES" >/dev/null
        echo "LINK=$link \ item-name=$item_name \ date=$(now_stamp)" | sudo tee "$WISHES_DIR/$wish_id.txt" >/dev/null
        echo "Amazon wish saved as $wish_id"

    elif [ "$wish_type" = "TEXT" ]; then
        echo "CREATING NEW TEXT WISH"
        echo "WHAT IS THE TEXT FOR THIS WISH?"
        read -r -p "TEXT: " text_wish

        while true; do
            read -r -p "IS THIS TEXT CORRECT: $text_wish?(Y,n) " ans
            case "$ans" in
                [Nn]*)
                    echo "WHAT IS THE CORRECT TEXT?"
                    read -r -p "TEXT: " text_wish
                    ;;
                [Yy]*|"") break ;;
                *) echo "Please answer Y or n." ;;
            esac
        done

        wish_id=$(gen_id)
        echo "$wish_id" | sudo tee -a "$GENERATED_NAMES" >/dev/null
        echo "TEXT=$text_wish \ date=$(now_stamp)" | sudo tee "$WISHES_DIR/$wish_id.txt" >/dev/null
        echo "Text wish saved as $wish_id"

    elif [ "$wish_type" = "OTHER" ]; then
        echo "COMING SOON..."
    else
        echo "Unknown wish type."
    fi
}

# --- Wishes menu with paging ---
show_wishes() {
    if [ ! -s "$GENERATED_NAMES" ]; then
        echo "No wishes yet."
        return
    fi

    reload_wishes_list
    page=0
    per_page=9

    while true; do
        clear
        echo "=== YOUR WISHES ==="
        start=$((page * per_page))
        end=$((start + per_page))
        [ $end -gt $total ] && end=$total

        # If page overflowed after deletions, pull back into range
        if [ $start -ge $total ] && [ $total -gt 0 ]; then
            page=$(( (total - 1) / per_page ))
            start=$((page * per_page))
            end=$((start + per_page))
            [ $end -gt $total ] && end=$total
        fi

        count_on_page=$((end - start))
        if [ $count_on_page -le 0 ]; then
            echo "No wishes on this page."
        else
            num=1
            for ((i=start; i<end; i++)); do
                wid="${wishes_list[$i]}"
                wish_file="$WISHES_DIR/$wid.txt"
                [ ! -f "$wish_file" ] && continue
                wish_data=$(cat "$wish_file")
                if [[ "$wish_data" == *"LINK="* ]]; then
                    type="AMAZON"; name=$(extract_field "$wish_data" "item-name"); [ -z "$name" ] && name="(no name)"
                elif [[ "$wish_data" == *"TEXT="* ]]; then
                    type="TEXT"; name=$(extract_field "$wish_data" "TEXT"); [ -z "$name" ] && name="(no text)"
                else
                    type="OTHER"; name=$(extract_field "$wish_data" "OTHER"); [ -z "$name" ] && name="(other)"
                fi
                echo "$num) [$type] $name"
                ((num++))
            done
        fi

        [ $end -lt $total ] && echo "0) Next Page"
        echo "X) Back to Menu"
        read -r -p "Choose: " choice

        # Next page
        if [ "$choice" = "0" ] && [ $end -lt $total ]; then
            ((page++))
            continue
        fi

        # Back
        [[ "$choice" =~ ^[Xx]$ ]] && break

        # Non-number → refresh
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            continue
        fi

        # Out of range → refresh
        if [ "$choice" -lt 1 ] || [ "$choice" -gt $((end - start)) ]; then
            continue
        fi

        # Resolve selected wish
        index=$((start + choice - 1))
        wid="${wishes_list[$index]}"
        wish_file="$WISHES_DIR/$wid.txt"
        [ ! -f "$wish_file" ] && continue
        wish_data=$(cat "$wish_file")

        if [[ "$wish_data" == *"LINK="* ]]; then
            type="AMAZON"
        elif [[ "$wish_data" == *"TEXT="* ]]; then
            type="TEXT"
        else
            type="OTHER"
        fi

        # Amazon actions
        if [ "$type" = "AMAZON" ]; then
            link=$(extract_field "$wish_data" "LINK")
            item_name=$(extract_field "$wish_data" "item-name")
            echo
            echo "Selected Amazon Wish: ${item_name:-"(no name)"}"
            echo "1) Open Link"
            echo "2) Delete Wish"
            echo "3) Edit Link or Name"
            read -r -p "Choose: " opt
            case "$opt" in
                1)
                    [ -n "$link" ] && xdg-open "$link" >/dev/null 2>&1 &
                    ;;
                2)
                    rm -f "$wish_file"
                    sudo sed -i "/^$wid$/d" "$GENERATED_NAMES"
                    reload_wishes_list
                    ;;
                3)
                    read -r -p "New Link (leave blank to keep): " new_link
                    [ -n "$new_link" ] && link="$new_link"
                    read -r -p "New Item Name (leave blank to keep): " new_name
                    [ -n "$new_name" ] && item_name="$new_name"
                    echo "LINK=$link \ item-name=$item_name \ date=$(now_stamp)" > "$wish_file"
                    ;;
                *)
                    : # any other input returns to list
                    ;;
            esac

        # Non-Amazon actions
        else
            echo
            echo "Selected $type Wish"
            echo "1) Delete Wish"
            echo "2) Edit Wish Text"
            read -r -p "Choose: " opt
            case "$opt" in
                1)
                    rm -f "$wish_file"
                    sudo sed -i "/^$wid$/d" "$GENERATED_NAMES"
                    reload_wishes_list
                    ;;
                2)
                    if [ "$type" = "TEXT" ]; then
                        current=$(extract_field "$wish_data" "TEXT")
                        read -r -p "New Text (leave blank to keep): " new_text
                        [ -z "$new_text" ] && new_text="$current"
                        echo "TEXT=$new_text \ date=$(now_stamp)" > "$wish_file"
                    else
                        current=$(extract_field "$wish_data" "OTHER")
                        read -r -p "New Description (leave blank to keep): " new_desc
                        [ -z "$new_desc" ] && new_desc="$current"
                        echo "OTHER=$new_desc \ date=$(now_stamp)" > "$wish_file"
                    fi
                    ;;
                *)
                    : # any other input returns to list
                    ;;
            esac
        fi
    done
}

# --- Settings ---
settings_menu() {
    while true; do
        echo
        echo "--- SETTINGS ---"
        echo "1) CHANGE USERNAME"
        echo "2) UPDATE"
        echo "3) BACK"
        read -r -p "Choose an option: " set_choice

        case "$set_choice" in
            1)
                read -r -p "Enter new username: " newname
                [ -z "$newname" ] && continue
                echo "NICKNAME=$newname" | sudo tee "$NAME_FILE" >/dev/null
                nickname="$newname"
                echo "Username updated to $nickname"
                ;;
            2)
                update_script
                ;;
            3)
                break
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
    done
}

# --- Main menu ---
while true; do
    echo
    echo "=== WISHNOW MENU ==="
    echo "1) NEW WISH"
    echo "2) WISHES"
    echo "3) SETTINGS"
    echo "4) EXIT"
    read -r -p "Choose an option: " choice

    case "$choice" in
        1) new_wish ;;
        2) show_wishes ;;
        3) settings_menu ;;
        4) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
