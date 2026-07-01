#!/bin/bash
# /etc/1002xOPERATOR/dns/adblock.sh
# DNS-based adblocking via dnsmasq sinkhole
# Blocklists are converted to dnsmasq address=domain/0.0.0.0 entries
# All devices using this DNS server are automatically protected

ADBLOCK_CONF="/etc/dnsmasq.d/1002x-adblock.conf"
ADBLOCK_DIR="/etc/1002xOPERATOR/dns/blocklists"
WHITELIST_FILE="/etc/1002xOPERATOR/dns/whitelist.txt"
SINKHOLE_IP="0.0.0.0"

grep -q "^filter-AAAA" /etc/dnsmasq.conf || echo "filter-AAAA" >> /etc/dnsmasq.conf
grep -q "log-queries" /etc/dnsmasq.conf || echo "log-queries" >> /etc/dnsmasq.conf; grep -q "log-facility" /etc/dnsmasq.conf || echo "log-facility=/var/log/dnsmasq.log" >> /etc/dnsmasq.conf

log()   { echo "[INFO] $1"; }
warn()  { echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

mkdir -p "$ADBLOCK_DIR"
touch "$WHITELIST_FILE" 2>/dev/null

reload_dns() {
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null
}

count_blocked() {
    grep -c '^address=' "$ADBLOCK_CONF" 2>/dev/null || echo 0
}

count_whitelist() {
    grep -vc '^#\|^$' "$WHITELIST_FILE" 2>/dev/null || echo 0
}

is_adblock_enabled() {
    [[ -f "$ADBLOCK_CONF" && $(count_blocked) -gt 0 ]]
}

# =========================
# Convert hosts/domain list → dnsmasq address= entries
# Supports: hosts format (0.0.0.0 domain) and plain domain lists
# =========================
_convert_list() {
    local src="$1"

    # Build whitelist lookup pattern
    local wl_pattern=""
    if [[ -s "$WHITELIST_FILE" ]]; then
        wl_pattern=$(grep -v '^#\|^$' "$WHITELIST_FILE" | sed 's/[.*[\^$]/\\&/g' | paste -sd'|' -)
    fi

    grep -v '^#\|^!\|^$' "$src" | \
    awk '{
        if ($1 == "0.0.0.0" || $1 == "127.0.0.1") { if ($2 != "") print $2 }
        else if (NF == 1 && $0 ~ /^[a-zA-Z0-9._-]+$/) print $0
    }' | \
    grep -v '^localhost$\|^0\.0\.0\.0$\|^127\.' | \
    { [[ -n "$wl_pattern" ]] && grep -Ev "^($wl_pattern)$" || cat; } | \
    sort -u
}

# =========================
# Rebuild adblock.conf from all loaded lists
# =========================
rebuild_conf() {
    local tmpconf
    tmpconf=$(mktemp)

    {
        echo "# 1002xOPERATOR DNS Adblock"
        echo "# Rebuilt: $(date)"
        echo "# Lists: $(ls -1 "$ADBLOCK_DIR"/*.txt 2>/dev/null | wc -l)"
        echo ""
    } > "$tmpconf"

    local total=0
    for f in "$ADBLOCK_DIR"/*.txt; do
        [[ -f "$f" ]] || continue
        local fname count
        fname=$(basename "$f")
        count=0
        while IFS= read -r domain; do
            [[ -z "$domain" ]] && continue
            echo "address=/$domain/$SINKHOLE_IP"
            count=$((count+1))
        done < <(_convert_list "$f") >> "$tmpconf"
        total=$((total+count))
        log "Processed $fname: $count entries"
    done

    mv "$tmpconf" "$ADBLOCK_CONF"
    reload_dns
    echo "$total"
}

# =========================
# Status overview
# =========================
show_status() {
    local blocked wl_count bl_count
    blocked=$(count_blocked)
    wl_count=$(count_whitelist)
    bl_count=$(ls -1 "$ADBLOCK_DIR"/*.txt 2>/dev/null | wc -l)

    local status_line
    if [[ "$blocked" -gt 0 ]]; then
        status_line="ENABLED  ($blocked domains blocked)"
    elif [[ -f "$ADBLOCK_CONF" ]]; then
        status_line="enabled but no entries loaded"
    else
        status_line="DISABLED"
    fi

    local list_info=""
    for f in "$ADBLOCK_DIR"/*.txt; do
        [[ -f "$f" ]] || continue
        local n; n=$(grep -vc '^#\|^!\|^$' "$f" 2>/dev/null || echo 0)
        list_info+="  $(basename "$f")  ($n raw entries)\n"
    done
    [[ -z "$list_info" ]] && list_info="  (none downloaded)\n"

    whiptail --title "DNS Adblock Status" --msgbox \
"Status    : $status_line
Whitelist : $wl_count entries
Lists     : $bl_count file(s)

Sinkhole IP : $SINKHOLE_IP
Config file : $ADBLOCK_CONF

Loaded blocklists:
${list_info}
All devices using this DNS server
are protected automatically." 22 62
}

# =========================
# Download preset blocklist
# =========================
download_preset() {
    local choice
    choice=$(whiptail --title "Download Preset Blocklist" \
        --menu "Select a blocklist:" 18 70 6 \
        "stevenblack"     "Steven Black Unified Hosts  (~130k domains)" \
        "someonewhocares" "Dan Pollock hosts            (~15k domains)" \
        "adaway"          "AdAway default hosts         (~400 entries)" \
        "oisd-small"      "OISD Small                   (~50k domains)" \
        "hagezi-light"    "HaGeZi Light                 (~200k domains)" \
        3>&1 1>&2 2>&3) || return

    local url
    case "$choice" in
        stevenblack)     url="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ;;
        someonewhocares) url="https://someonewhocares.org/hosts/hosts" ;;
        adaway)          url="https://adaway.org/hosts.txt" ;;
        oisd-small)      url="https://small.oisd.nl/domainswild" ;;
        hagezi-light)    url="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt" ;;
    esac

    whiptail --infobox "Downloading $choice ..." 6 50

    local tmpfile; tmpfile=$(mktemp)
    if curl -fsSL --max-time 120 "$url" -o "$tmpfile" 2>/dev/null \
    || wget -qO "$tmpfile" --timeout=120 "$url" 2>/dev/null; then
        local raw; raw=$(grep -vc '^#\|^!\|^$' "$tmpfile" 2>/dev/null || echo 0)
        mv "$tmpfile" "$ADBLOCK_DIR/${choice}.txt"
        local total; total=$(rebuild_conf)
        whiptail --msgbox \
"Downloaded: ${choice}.txt
Raw entries  : $raw
Total blocked: $total domains" 10 55
    else
        rm -f "$tmpfile"
        whiptail --msgbox "Download of $choice failed.\nCheck internet connection." 9 55
    fi
}

# =========================
# Download custom URL
# =========================
download_custom() {
    local url name

    url=$(whiptail --inputbox "Blocklist URL (hosts or plain domain format):" 8 68 \
        3>&1 1>&2 2>&3) || return
    [[ -z "$url" ]] && return

    name=$(whiptail --inputbox "Name for this list (without .txt):" 8 55 \
        3>&1 1>&2 2>&3) || return
    name="${name//[^a-zA-Z0-9_-]/}"
    [[ -z "$name" ]] && { whiptail --msgbox "Invalid name." 8 50; return; }

    whiptail --infobox "Downloading $name ..." 6 55

    local tmpfile; tmpfile=$(mktemp)
    if curl -fsSL --max-time 60 "$url" -o "$tmpfile" 2>/dev/null \
    || wget -qO "$tmpfile" --timeout=60 "$url" 2>/dev/null; then
        local raw; raw=$(grep -vc '^#\|^!\|^$' "$tmpfile" 2>/dev/null || echo 0)
        mv "$tmpfile" "$ADBLOCK_DIR/${name}.txt"
        local total; total=$(rebuild_conf)
        whiptail --msgbox \
"Downloaded: ${name}.txt
Raw entries  : $raw
Total blocked: $total domains" 10 55
    else
        rm -f "$tmpfile"
        whiptail --msgbox "Download failed.\nCheck URL and connection." 9 55
    fi
}

# =========================
# Show / remove loaded lists
# =========================
manage_lists() {
    while true; do
        local menu_opts=()
        for f in "$ADBLOCK_DIR"/*.txt; do
            [[ -f "$f" ]] || continue
            local n; n=$(grep -vc '^#\|^!\|^$' "$f" 2>/dev/null || echo 0)
            menu_opts+=("$(basename "$f")" "$n raw entries")
        done

        if [[ ${#menu_opts[@]} -eq 0 ]]; then
            whiptail --msgbox "No blocklists loaded yet." 8 50
            return
        fi

        local choice
        choice=$(whiptail --title "Loaded Blocklists" \
            --menu "Select a list to remove (or Cancel to go back):" 20 62 10 \
            "${menu_opts[@]}" 3>&1 1>&2 2>&3) || return

        whiptail --yesno "Remove blocklist: $choice?" 8 50 || continue

        rm -f "$ADBLOCK_DIR/$choice"
        local total; total=$(rebuild_conf)
        whiptail --msgbox "$choice removed.\nTotal blocked domains now: $total" 9 55
    done
}

# =========================
# Block a domain manually
# =========================
add_domain() {
    local domain
    domain=$(whiptail --inputbox "Domain to block (e.g. ads.example.com):" 8 60 \
        3>&1 1>&2 2>&3) || return
    domain="${domain//[^a-zA-Z0-9._-]/}"
    [[ -z "$domain" ]] && { whiptail --msgbox "Invalid domain." 8 50; return; }

    local manual="$ADBLOCK_DIR/manual.txt"
    touch "$manual"

    if grep -qx "$domain" "$manual" 2>/dev/null; then
        whiptail --msgbox "$domain is already in the manual block list." 8 55
        return
    fi

    echo "$domain" >> "$manual"
    rebuild_conf > /dev/null
    whiptail --msgbox "$domain added to manual block list." 8 55
    log "Manually blocked: $domain"
}

# =========================
# Whitelist management
# =========================
manage_whitelist() {
    while true; do
        local wl_count; wl_count=$(count_whitelist)

        local choice
        choice=$(whiptail --title "Whitelist [$wl_count entries]" \
            --menu "Select action:" 14 55 4 \
            "show"   "Show whitelist entries" \
            "add"    "Add domain to whitelist" \
            "delete" "Remove domain from whitelist" \
            "exit"   "Back" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            show)
                local entries
                entries=$(grep -v '^#\|^$' "$WHITELIST_FILE" 2>/dev/null)
                if [[ -z "$entries" ]]; then
                    whiptail --msgbox "Whitelist is empty." 8 50
                else
                    whiptail --title "Whitelist" --scrolltext --msgbox "$entries" 20 60
                fi
                ;;
            add)
                local domain
                domain=$(whiptail --inputbox "Domain to whitelist (never blocked):" 8 58 \
                    3>&1 1>&2 2>&3) || continue
                domain="${domain//[^a-zA-Z0-9._-]/}"
                [[ -z "$domain" ]] && continue
                if grep -qx "$domain" "$WHITELIST_FILE" 2>/dev/null; then
                    whiptail --msgbox "$domain is already whitelisted." 8 50
                    continue
                fi
                echo "$domain" >> "$WHITELIST_FILE"
                rebuild_conf > /dev/null
                whiptail --msgbox "$domain whitelisted and adblock rebuilt." 8 58
                ;;
            delete)
                local entries=()
                local idx=1
                while IFS= read -r line; do
                    [[ -z "$line" || "$line" =~ ^# ]] && continue
                    entries+=("$idx" "$line")
                    idx=$((idx+1))
                done < "$WHITELIST_FILE"

                if [[ ${#entries[@]} -eq 0 ]]; then
                    whiptail --msgbox "Whitelist is empty." 8 50
                    continue
                fi

                local sel
                sel=$(whiptail --title "Remove from Whitelist" \
                    --menu "Select entry to remove:" 18 60 8 \
                    "${entries[@]}" 3>&1 1>&2 2>&3) || continue

                local entry
                entry=$(grep -v '^#\|^$' "$WHITELIST_FILE" | sed -n "${sel}p")
                whiptail --yesno "Remove '$entry' from whitelist?" 8 55 || continue

                local escaped; escaped=$(echo "$entry" | sed 's/[.*[\^$]/\\&/g')
                sed -i "/^${escaped}$/d" "$WHITELIST_FILE"
                rebuild_conf > /dev/null
                whiptail --msgbox "$entry removed from whitelist." 8 55
                ;;
            exit) break ;;
        esac
    done
}

# =========================
# Enable / Disable toggle
# =========================
toggle_adblock() {
    if is_adblock_enabled; then
        whiptail --yesno "Adblocking is currently ACTIVE.\nDisable it?" 8 50 || return
        echo "# 1002xOPERATOR DNS Adblock – disabled" > "$ADBLOCK_CONF"
        reload_dns
        whiptail --msgbox "Adblocking disabled. dnsmasq reloaded." 8 55
    else
        whiptail --yesno "Adblocking is currently DISABLED.\nRebuild and enable it now?" 8 58 || return
        local total; total=$(rebuild_conf)
        if [[ "$total" -gt 0 ]]; then
            whiptail --msgbox "Adblocking enabled.\n$total domains blocked." 9 50
        else
            whiptail --msgbox "Adblocking enabled but no lists loaded.\nUse 'Download preset blocklist' to add one." 10 58
        fi
    fi
}

# =========================
# Update all downloaded lists
# =========================
update_all() {
    declare -A PRESET_URLS
    PRESET_URLS["stevenblack.txt"]="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    PRESET_URLS["someonewhocares.txt"]="https://someonewhocares.org/hosts/hosts"
    PRESET_URLS["adaway.txt"]="https://adaway.org/hosts.txt"
    PRESET_URLS["oisd-small.txt"]="https://small.oisd.nl/domainswild"
    PRESET_URLS["hagezi-light.txt"]="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt"

    local updated=0 skipped=0
    for fname in "${!PRESET_URLS[@]}"; do
        [[ ! -f "$ADBLOCK_DIR/$fname" ]] && continue
        local url="${PRESET_URLS[$fname]}"
        whiptail --infobox "Updating $fname ..." 6 55
        local tmpfile; tmpfile=$(mktemp)
        if curl -fsSL --max-time 120 "$url" -o "$tmpfile" 2>/dev/null \
        || wget -qO "$tmpfile" --timeout=120 "$url" 2>/dev/null; then
            mv "$tmpfile" "$ADBLOCK_DIR/$fname"
            updated=$((updated+1))
            log "Updated: $fname"
        else
            rm -f "$tmpfile"
            warn "Failed to update: $fname"
            skipped=$((skipped+1))
        fi
    done

    if [[ "$updated" -eq 0 && "$skipped" -eq 0 ]]; then
        whiptail --msgbox "No preset lists found to update.\n(manual.txt is not auto-updated)" 9 58
        return
    fi

    local total; total=$(rebuild_conf)
    whiptail --msgbox \
"Update complete.
Updated : $updated list(s)
Skipped : $skipped list(s)
Total blocked: $total domains" 11 50
}

# =========================
# Main loop
# =========================
while true; do
    blocked=$(count_blocked)
    if [[ "$blocked" -gt 0 ]]; then
        hdr="$blocked domains blocked"
    else
        hdr="DISABLED"
    fi

    CHOICE=$(whiptail --title "1002xOPERATOR – DNS Adblock [$hdr]" \
        --menu "Select action:" 20 65 9 \
        "status"    "Show status and loaded lists" \
        "preset"    "Download preset blocklist" \
        "download"  "Download custom blocklist URL" \
        "lists"     "Show / remove loaded lists" \
        "block"     "Block a domain manually" \
        "whitelist" "Manage whitelist" \
        "update"    "Update all downloaded lists" \
        "toggle"    "Enable / Disable adblocking" \
        "exit"      "Back to menu" \
        3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$CHOICE" == "exit" ]] && exit 0

    case "$CHOICE" in
        status)    show_status ;;
        preset)    download_preset ;;
        download)  download_custom ;;
        lists)     manage_lists ;;
        block)     add_domain ;;
        whitelist) manage_whitelist ;;
        update)    update_all ;;
        toggle)    toggle_adblock ;;
    esac
    echo "[INFO] Restart dnsmasq service"
    systemctl restart dnsmasq
done
