#!/bin/bash

# -------------------------------
# WISHNOW - single-file Bash app
# -------------------------------

CONFIG_DIR="/usr/local/etc/WISHNOW/user"
NAME_FILE="$CONFIG_DIR/NAME.txt"
SETTINGS_DIR="$CONFIG_DIR/SETTINGS"
WISHES_DIR="$CONFIG_DIR/WISHES"
GENERATED_NAMES="$SETTINGS_DIR/generated-names.txt"

mkdir -p "$CONFIG_DIR"

# --- First run setup ---
if [ ! -f "$NAME_FILE" ]; then
    echo "HELLO USER!"
    read -p "WHAT SHOULD I CALL YOU? NAME: " nickname
    sudo mkdir -p "$CONFIG_DIR"
    echo "NICKNAME=$nickname" | sudo tee "$NAME_FILE" > /dev/null
    echo "HELLO $nickname"
else
    nickname=$(grep -m1 "NICKNAME=" "$NAME_FILE" | cut -d'=' -f2)
    [ -z "$nickname" ] && nickname="FRIEND"
    echo "HELLO $nickname"
fi

# Ensure base folders exist
sudo mkdir -p "$SETTINGS_DIR" "$WISHES_DIR"
sudo touch "$GENERATED_NAMES"

# --- Helpers ---
gen_id() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8
}
now_stamp() {
    date +"%H/%M/%S/%3N/%m/%d/%Y"
}
extract_field() {
    # $1 = data, $2 = key (LINK|item-name|TEXT|OTHER)
    echo "$1" | sed -n "s/.*$2=\([^\\]*\).*/\1/p"
}
reload_wishes_list() {
    wishes_list=($(cat "$GENERATED_NAMES"))
    total=${#wishes_list[@]}
}

# --- NEW WISH flow ---
new_wish() {
    echo "WHAT KIND OF WISH IS THIS? (AMAZON,TEXT,OTHER)"
    read -p "> " wish_type
    wish_type=$(echo "$wish_type" | tr '[:lower:]' '[:upper:]')

    echo "CREATING NEW WISH..."

    if [ "$wish_type" = "AMAZON" ]; then
        echo "SELECTED : AMAZON"

        echo "WHAT IS THE AMAZON LINK?"
        read -p " LINK: " link
        echo " AMAZON LINK ADDED"

        echo "WHAT IS THE NAME OF THE AMAZON ITEM"
        read -p "ITEM-NAME: " item_name

        while true; do
            read -p "IS THE LINK CORRECT: $link?(Y,n) " ans
            case "$ans" in
                [Nn]*)
                    echo "WHAT IS THE CORRECT LINK?"
                    read -p "LINK: " link
                    ;;
                [Yy]*|"")
                    break
                    ;;
                *)
                    echo "Please answer Y or n."
                    ;;
            esac
        done

        while true; do
            read -p "IS THE ITEM NAME CORRECT: $item_name?(Y,n) " ans
            case "$ans" in
                [Nn]*)
                    echo "WHAT IS THE CORRECT ITEM NAME?"
                    read -p "ITEM-NAME: " item_name
                    ;;
                [Yy]*|"")
                    break
                    ;;
                *)
                    echo "Please answer Y or n."
                    ;;
            esac
        done

        wish_id=$(gen_id)
        echo "$wish_id" | sudo tee -a "$GENERATED_NAMES" > /dev/null
        timestamp=$(now_stamp)
        echo "LINK=$link \ item-name=$item_name \ date=$timestamp" | sudo tee "$WISHES_DIR/$wish_id.txt" > /dev/null
        echo "Amazon wish saved as $wish_id"

    elif [ "$wish_type" = "TEXT" ]; then
        echo "CREATING NEW TEXT WISH"
        echo "WHAT IS THE TEXT FOR THIS WISH?"
        read -p "TEXT: " text_wish

        while true; do
            read -p "IS THIS TEXT CORRECT: $text_wish?(Y,n) " ans
            case "$ans" in
                [Nn]*)
                    echo "WHAT IS THE CORRECT TEXT?"
                    read -p "TEXT: " text_wish
                    ;;
                [Yy]*|"")
                    break
                    ;;
                *)
                    echo "Please answer Y or n."
                    ;;
            esac
        done

        wish_id=$(gen_id)
        echo "$wish_id" | sudo tee -a "$GENERATED_NAMES" > /dev/null
        timestamp=$(now_stamp)
        echo "TEXT=$text_wish \ date=$timestamp" | sudo tee "$WISHES_DIR/$wish_id.txt" > /dev/null
        echo "Text wish saved as $wish_id"

    elif [ "$wish_type" = "OTHER" ]; then
        echo "COMING SOON..."
    else
        echo "Unknown wish type."
    fi
}

# --- WISHES (paged) ---
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

        if [ $start -ge $total ]; then
            page=0
            start=0
            end=$((start + per_page))
            [ $end -gt $total ] && end=$total
        fi

        num=1
        for ((i=start; i<end; i++)); do
            wid="${wishes_list[$i]}"
            wish_path="$WISHES_DIR/$wid.txt"
            if [ ! -f "$wish_path" ]; then
                continue
            fi
            wish_data=$(cat "$wish_path")
            if [[ "$wish_data" == *"LINK="* ]]; then
                type="AMAZON"
                name=$(extract_field "$wish_data" "item-name")
                [ -z "$name" ] && name="(no name)"
            elif [[ "$wish_data" == *"TEXT="* ]]; then
                type="TEXT"
                name=$(extract_field "$wish_data" "TEXT")
                [ -z "$name" ] && name="(no text)"
            else
                type="OTHER"
                name=$(extract_field "$wish_data" "OTHER")
                [ -z "$name" ] && name="(other)"
            fi
            echo "$num) [$type] $name"
            ((num++))
        done

        [ $end -lt $total ] && echo "0) Next Page"
        echo "X) Back to Menu"
        read -p "Choose: " choice

        if [ "$choice" = "0" ] && [ $end -lt $total ]; then
            ((page++))
            continue
        fi

        [[ "$choice" =~ ^[Xx]$ ]] && break

        # validate numeric selection
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            # any non-number → just refresh the list
            continue
        fi
        if [ "$choice" -lt 1 ] || [ "$choice" -gt $((end-start)) ]; then
            # out of range → refresh the list
            continue
        fi

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

        # AMAZON wish actions
        if [ "$type" = "AMAZON" ]; then
            link=$(extract_field "$wish_data" "LINK")
            item_name=$(extract_field "$wish_data" "item-name")
            echo
            echo "Selected Amazon Wish: ${item_name:-"(no name)"}"
            echo "1) Open Link"
            echo "2) Delete Wish"
            echo "3) Edit Link or Name"
            read -p "Choose: " opt
            case "$opt" in
                1)
                    if [ -n "$link" ]; then
                        xdg-open "$link" >/dev/null 2>&1 &
                    fi
                    ;;
                2)
                    rm -f "$wish_file"
                    sed -i "/^$wid$/d" "$GENERATED_NAMES"
                    # refresh list and keep on same page if possible
                    reload_wishes_list
                    [ $((page*per_page)) -ge $total ] && page=$(( (total-1)/per_page ))
                    ;;
                3)
                    read -p "New Link (leave blank to keep): " new_link
                    [ -n "$new_link" ] && link="$new_link"
                    read -p "New Item Name (leave blank to keep): " new_name
                    [ -n "$new_name" ] && item_name="$new_name"
                    timestamp=$(now_stamp)
                    echo "LINK=$link \ item-name=$item_name \ date=$timestamp" > "$wish_file"
                    ;;
                *)
                    # any other key → back to the list
                    :
                    ;;
            esac

        # NON-AMAZON actions
        else
            echo
            echo "Selected $type Wish"
            echo "1) Delete Wish"
            echo "2) Edit Wish Text"
            read -p "Choose: " opt
            case "$opt" in
                1)
                    rm -f "$wish_file"
                    sed -i "/^$wid$/d" "$GENERATED_NAMES"
                    reload_wishes_list
                    [ $((page*per_page)) -ge $total ] && page=$(( (total-1)/per_page ))
                    ;;
                2)
                    if [ "$type" = "TEXT" ]; then
                        current=$(extract_field "$wish_data" "TEXT")
                        read -p "New Text (leave blank to keep): " new_text
                        [ -z "$new_text" ] && new_text="$current"
                        timestamp=$(now_stamp)
                        echo "TEXT=$new_text \ date=$timestamp" > "$wish_file"
                    else
                        current=$(extract_field "$wish_data" "OTHER")
                        read -p "New Description (leave blank to keep): " new_desc
                        [ -z "$new_desc" ] && new_desc="$current"
                        timestamp=$(now_stamp)
                        echo "OTHER=$new_desc \ date=$timestamp" > "$wish_file"
                    fi
                    ;;
                *)
                    # any other key → back to the list
                    :
                    ;;
            esac
        fi
    done
}

# --- SETTINGS ---
settings_menu() {
    while true; do
        echo
        echo "--- SETTINGS ---"
        echo "1) CHANGE USERNAME"
        echo "2) UPDATE"
        echo "3) BACK"
        read -p "Choose an option: " set_choice

        case "$set_choice" in
            1)
                read -p "Enter new username: " newname
                [ -z "$newname" ] && continue
                echo "NICKNAME=$newname" | sudo tee "$NAME_FILE" > /dev/null
                nickname="$newname"
                echo "Username updated to $nickname"
                ;;
            2)
                echo "WE ARE STILL WORKING ON WISHNOW RIGHT NOW"
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

# --- Main menu loop ---
while true; do
    echo
    echo "=== WISHNOW MENU ==="
    echo "1) NEW WISH"
    echo "2) WISHES"
    echo "3) SETTINGS"
    echo "4) EXIT"
    read -p "Choose an option: " choice

    case "$choice" in
        1) new_wish ;;
        2) show_wishes ;;
        3) settings_menu ;;
        4) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
