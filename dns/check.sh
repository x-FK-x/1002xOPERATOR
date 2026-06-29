#!/bin/bash
# /etc/1002xOPERATOR/dns/check.sh
# dnsmasq status checks and diagnostics

DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_D="/etc/dnsmasq.d"
LOCAL_HOSTS="$DNSMASQ_D/1002x-local-hosts.conf"
CUSTOM_ZONES="$DNSMASQ_D/1002x-custom-zones.conf"
ADBLOCK_CONF="$DNSMASQ_D/1002x-adblock.conf"

log()   { echo "[INFO] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

# =========================
# Status overview
# =========================
show_status() {
    local svc_status pid version
    svc_status=$(systemctl is-active dnsmasq 2>/dev/null || echo "unknown")
    pid=$(pgrep dnsmasq | head -1)
    version=$(dnsmasq --version 2>/dev/null | head -1 | awk '{print $3}')

    local host_count zone_count blocked_count
    host_count=$(grep -vc '^#\|^$' "$LOCAL_HOSTS" 2>/dev/null || echo 0)
    zone_count=$(grep -vc '^#\|^$' "$CUSTOM_ZONES" 2>/dev/null || echo 0)
    blocked_count=$(grep -c '^address=' "$ADBLOCK_CONF" 2>/dev/null || echo 0)

    local upstream
    upstream=$(grep -E '^server=[0-9]' "$DNSMASQ_CONF" 2>/dev/null | sed 's/^server=//' | tr '\n' '  ')
    [[ -z "$upstream" ]] && upstream="(none configured)"

    local domain
    domain=$(grep '^domain=' "$DNSMASQ_CONF" 2>/dev/null | cut -d= -f2)

    local lan_if lan_ip
    lan_if=$(grep '^interface=' "$DNSMASQ_CONF" 2>/dev/null | cut -d= -f2 | head -1)
    lan_ip=$(ip -4 addr show dev "$lan_if" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I | awk '{print $1}')

    local adblock_status
    if [[ -f "$ADBLOCK_CONF" && "$blocked_count" -gt 0 ]]; then
        adblock_status="ENABLED  ($blocked_count domains)"
    elif [[ -f "$ADBLOCK_CONF" ]]; then
        adblock_status="enabled but empty (run adblock.sh)"
    else
        adblock_status="disabled"
    fi

    whiptail --title "dnsmasq Status" --msgbox \
"Service   : $svc_status
Version   : ${version:-unknown}
PID       : ${pid:-(not running)}

Interface : ${lan_if:-(auto)}  ($lan_ip)
Domain    : ${domain:-(not set)}
Upstream  : $upstream

Local hosts   : $host_count entries
Custom zones  : $zone_count entries
Adblock       : $adblock_status

Config    : $DNSMASQ_CONF" 20 65
}

# =========================
# Config syntax test
# =========================
test_config() {
    local result
    result=$(dnsmasq --test 2>&1)
    if [[ $? -eq 0 ]]; then
        whiptail --title "Config Test" --msgbox "Config syntax OK:\n\n$result" 10 60
    else
        whiptail --title "Config Test" --msgbox "Config ERROR:\n\n$result" 12 68
    fi
}

# =========================
# Service control
# =========================
service_control() {
    local action
    action=$(whiptail --title "Service Control" \
        --menu "dnsmasq service action:" 14 50 5 \
        "start"   "Start dnsmasq" \
        "stop"    "Stop dnsmasq" \
        "restart" "Restart dnsmasq" \
        "reload"  "Reload config (no downtime)" \
        "status"  "Show systemctl status output" \
        3>&1 1>&2 2>&3) || return

    case "$action" in
        start)
            systemctl start dnsmasq
            whiptail --msgbox "dnsmasq started." 8 50 ;;
        stop)
            systemctl stop dnsmasq
            whiptail --msgbox "dnsmasq stopped." 8 50 ;;
        restart)
            systemctl restart dnsmasq
            whiptail --msgbox "dnsmasq restarted." 8 50 ;;
        reload)
            systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null
            whiptail --msgbox "Config reloaded." 8 50 ;;
        status)
            local out
            out=$(systemctl status dnsmasq 2>&1 | head -30)
            whiptail --title "systemctl status dnsmasq" --scrolltext --msgbox "$out" 22 72 ;;
    esac
}

# =========================
# View log
# =========================
view_log() {
    local lines
    lines=$(whiptail --inputbox "How many log lines to show?" 8 50 "60" 3>&1 1>&2 2>&3) || return
    [[ ! "$lines" =~ ^[0-9]+$ ]] && lines=60

    local log_out
    log_out=$(journalctl -u dnsmasq -n "$lines" --no-pager 2>/dev/null \
           || tail -n "$lines" /var/log/dnsmasq.log 2>/dev/null \
           || echo "(no log available)")

    whiptail --title "dnsmasq Log (last $lines lines)" --scrolltext \
        --msgbox "$log_out" 24 80
}

# =========================
# DNS resolution tests
# =========================
run_tests() {
    local custom_domain
    custom_domain=$(whiptail --inputbox \
        "Additional domain to test (leave empty to skip):" 8 60 3>&1 1>&2 2>&3)
    custom_domain="${custom_domain//[^a-zA-Z0-9._-]/}"

    local test_domains=("google.com" "cloudflare.com" "github.com")
    [[ -n "$custom_domain" ]] && test_domains+=("$custom_domain")

    local results=""
    for d in "${test_domains[@]}"; do
        [[ -z "$d" ]] && continue
        local res
        res=$(dig +short +time=2 +tries=1 "$d" @127.0.0.1 2>/dev/null | head -1)
        if [[ -n "$res" ]]; then
            results+="  [OK]   $d  →  $res\n"
        else
            results+="  [FAIL] $d  →  no answer\n"
        fi
    done

    whiptail --title "DNS Resolution Tests (via 127.0.0.1)" \
        --msgbox "$results" 14 65
}

# =========================
# Show port 53 listeners
# =========================
show_listeners() {
    local out
    out=$(ss -tlnp 2>/dev/null | grep ':53' \
       || netstat -tlnp 2>/dev/null | grep ':53' \
       || echo "(ss/netstat not available)")
    whiptail --title "Port 53 Listeners" --scrolltext --msgbox "$out" 14 75
}

# =========================
# Main loop
# =========================
while true; do
    svc_label=$(systemctl is-active dnsmasq 2>/dev/null || echo "unknown")

    CHOICE=$(whiptail --title "1002xOPERATOR – DNS Check [$svc_label]" \
        --menu "Select action:" 18 60 7 \
        "status"    "Show full status overview" \
        "config"    "Test config syntax (dnsmasq --test)" \
        "service"   "Start / Stop / Restart / Reload" \
        "log"       "View live log" \
        "test"      "Test DNS resolution" \
        "listeners" "Show port 53 listeners" \
        "exit"      "Back to menu" \
        3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$CHOICE" == "exit" ]] && exit 0

    case "$CHOICE" in
        status)    show_status ;;
        config)    test_config ;;
        service)   service_control ;;
        log)       view_log ;;
        test)      run_tests ;;
        listeners) show_listeners ;;
    esac
done
