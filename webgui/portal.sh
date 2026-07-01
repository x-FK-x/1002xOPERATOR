#!/bin/bash
# /etc/1002xOPERATOR/webgui/portal.sh
# 1002xOPERATOR Portal
# Port 8080

PORT="${1:-8080}"
SERVICE_DIR="/etc/systemd/system"

log() { echo "[portal] $1"; }

# ── Helpers ──────────────────────────────────────────────────────────────────
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

get_post_value() {
    local body="$1" key="$2"
    local val
    val=$(echo "$body" | tr '&' '\n' | grep "^${key}=" | head -n1 | cut -d'=' -f2-)
    urldecode "$val"
}

svc_active()    { systemctl is-active    "$1" 2>/dev/null | grep -q '^active$'  && echo 1 || echo 0; }
svc_installed() { [[ -f "$SERVICE_DIR/$1.service" ]] && echo 1 || echo 0; }

uninstall_service() {
    local svc="$1"
    systemctl stop    "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
    rm -f "$SERVICE_DIR/$svc.service"
    systemctl daemon-reload 2>/dev/null
    local port
    case "$svc" in
        1002x-dhcp-webui)  port=8081 ;;
        1002x-samba-webui) port=8082 ;;
        1002x-ufw-webui)   port=8083 ;;
        1002x-dns-webui)   port=8084 ;;
    esac
    [[ -n "$port" ]] && fuser -k "${port}/tcp" 2>/dev/null || true
}

handle_request() {
    local method path content_length body_raw
    read -r method path _
    path="${path//$'\r'/}"
    method="${method//$'\r'/}"
    while IFS= read -r line; do
        line="${line%$'\r'}"; [[ -z "$line" ]] && break
        [[ "$line" =~ ^Content-Length:\ ([0-9]+) ]] && content_length="${BASH_REMATCH[1]}"
    done
    [[ "$method" == "POST" && -n "$content_length" && "$content_length" -gt 0 ]] \
        && body_raw=$(dd bs=1 count="$content_length" 2>/dev/null)
    path="${path%%\?*}"

    local HOST_IP LAN_IF
    LAN_IF=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    HOST_IP=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$HOST_IP" ]] && HOST_IP=$(hostname -I | awk '{print $1}')

    # ── POST /uninstall ───────────────────────────────────────────────────────
    if [[ "$method" == "POST" && "$path" == "/uninstall" ]]; then
        local svc; svc=$(get_post_value "$body_raw" "svc")
        case "$svc" in
            1002x-dhcp-webui|1002x-samba-webui|1002x-ufw-webui|1002x-dns-webui)
                uninstall_service "$svc" ;;
        esac
        printf "HTTP/1.1 302 Found\r\nLocation: /\r\nConnection: close\r\n\r\n"
        return
    fi

    # ── POST /toggle ──────────────────────────────────────────────────────────
    if [[ "$method" == "POST" && "$path" == "/toggle" ]]; then
        local svc; svc=$(get_post_value "$body_raw" "svc")
        case "$svc" in
            1002x-dhcp-webui|1002x-samba-webui|1002x-ufw-webui|1002x-dns-webui)
                if [[ $(svc_active "$svc") -eq 1 ]]; then
                    systemctl stop  "$svc" 2>/dev/null
                else
                    systemctl start "$svc" 2>/dev/null
                fi ;;
        esac
        printf "HTTP/1.1 302 Found\r\nLocation: /\r\nConnection: close\r\n\r\n"
        return
    fi

    # ── GET / ─────────────────────────────────────────────────────────────────
    local wan_status samba_status dhcp_status ufw_status dns_status
    wan_status=$(systemctl is-active wan-failover 2>/dev/null)
    samba_status=$(systemctl is-active smbd 2>/dev/null)
    dhcp_status=$(systemctl is-active isc-dhcp-server 2>/dev/null)
    ufw_status=$(sudo ufw status 2>/dev/null | head -1 | awk '{print $2}')
    dns_status=$(systemctl is-active dnsmasq 2>/dev/null)

    local wan_color samba_color dhcp_color ufw_color dns_color
    [[ "$wan_status"   == "active" ]] && wan_color="#00ff88"   || wan_color="#ff3860"
    [[ "$samba_status" == "active" ]] && samba_color="#00ff88" || samba_color="#ff3860"
    [[ "$dhcp_status"  == "active" ]] && dhcp_color="#00ff88"  || dhcp_color="#ff3860"
    [[ "$ufw_status"   == "active" ]] && ufw_color="#00ff88"   || ufw_color="#ff3860"
    [[ "$dns_status"   == "active" ]] && dns_color="#00ff88"   || dns_color="#ff3860"

    local adblock_count
    adblock_count=$(grep -c '^address=' /etc/dnsmasq.d/1002x-adblock.conf 2>/dev/null || echo 0)

    local dhcp_wa dhcp_wi samba_wa samba_wi ufw_wa ufw_wi dns_wa dns_wi
    dhcp_wa=$(svc_active    "1002x-dhcp-webui");  dhcp_wi=$(svc_installed  "1002x-dhcp-webui")
    samba_wa=$(svc_active   "1002x-samba-webui"); samba_wi=$(svc_installed "1002x-samba-webui")
    ufw_wa=$(svc_active     "1002x-ufw-webui");   ufw_wi=$(svc_installed   "1002x-ufw-webui")
    dns_wa=$(svc_active     "1002x-dns-webui");   dns_wi=$(svc_installed   "1002x-dns-webui")

    # WAN interface pills
    local wan_ifaces=""
    local priority_file="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
    local state_file="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
    if [[ -f "$priority_file" ]]; then
        local wan_list
        wan_list=$(tail -n1 "$priority_file")
        for iface in $wan_list; do
            local ip state suppressed dot_color
            ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet/ {print $2}' | head -n1)
            state=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "?")
            grep -q "^SUPPRESSED $iface " "$state_file" 2>/dev/null && suppressed=1 || suppressed=0
            if   [[ "$suppressed" -eq 1 ]]; then dot_color="#ff3860"
            elif [[ "$state" == "up" ]];    then dot_color="#00ff88"
            else                                 dot_color="#ff3860"; fi
            wan_ifaces+="<div class='iface-pill'><span class='dot' style='background:$dot_color'></span><span class='iface-name'>$iface</span><span class='iface-ip'>${ip:-no ip}</span></div>"
        done
    fi

    # Build module card HTML
    # args: svc port color icon title desc tags wa wi
    make_card() {
        local svc="$1" port="$2" color="$3" icon="$4" title="$5" desc="$6" tags="$7" wa="$8" wi="$9"
        local dot_color toggle_label toggle_class controls
        if   [[ "$wi" -eq 0 ]]; then dot_color="#64748b"
        elif [[ "$wa" -eq 1 ]]; then dot_color="#00ff88"
        else                         dot_color="#ff3860"; fi
        if [[ "$wa" -eq 1 ]]; then toggle_label="■ Stop";  toggle_class="btn-stop"
        else                        toggle_label="▶ Start"; toggle_class="btn-go"; fi
        if [[ "$wi" -eq 1 ]]; then
            controls=""
        else
            controls=""
        fi
        echo "<div class='module-wrap'>
  <a href='http://$HOST_IP:$port' class='module' style='--module-color:$color'>
    <span class='module-port'>:$port</span>
    <span class='module-dot' style='background:$dot_color'></span>
    <span class='module-icon'>$icon</span>
    <div class='module-title'>$title</div>
    <div class='module-desc'>$desc</div>
    <div class='module-tags'>$tags</div>
  </a>
  $controls
</div>"
    }

    printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>1002xOPERATOR</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Syne:wght@400;700;800;900&display=swap');
  :root{--bg:#0a0c10;--surface:#111318;--border:#1e2230;--accent:#00e5ff;--accent2:#ff6b35;--green:#00ff88;--red:#ff3860;--text:#e2e8f0;--muted:#64748b}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:40px 20px}
  body::before{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,229,255,0.012) 2px,rgba(0,229,255,0.012) 4px);pointer-events:none}
  body::after{content:'';position:fixed;inset:0;background-image:linear-gradient(rgba(0,229,255,0.03) 1px,transparent 1px),linear-gradient(90deg,rgba(0,229,255,0.03) 1px,transparent 1px);background-size:40px 40px;pointer-events:none}
  .container{position:relative;z-index:1;width:100%;max-width:1000px}
  .hero{text-align:center;margin-bottom:48px}
  .hero-label{font-size:11px;letter-spacing:4px;text-transform:uppercase;color:var(--muted);margin-bottom:12px}
  .hero-title{font-family:'Syne',sans-serif;font-size:clamp(42px,8vw,80px);font-weight:900;line-height:1;color:var(--accent);letter-spacing:-2px}
  .hero-title span{color:var(--accent2)}
  .hero-sub{font-size:12px;color:var(--muted);margin-top:12px;letter-spacing:2px}
  .status-bar{display:flex;gap:20px;justify-content:center;flex-wrap:wrap;margin-bottom:40px}
  .status-item{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--muted)}
  .status-dot{width:8px;height:8px;border-radius:50%;animation:pulse 2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:0.4}}
  .iface-pills{display:flex;gap:10px;justify-content:center;flex-wrap:wrap;margin-bottom:40px}
  .iface-pill{display:flex;align-items:center;gap:8px;background:var(--surface);border:1px solid var(--border);border-radius:20px;padding:6px 14px;font-size:12px}
  .dot{width:7px;height:7px;border-radius:50%}
  .iface-name{color:var(--accent);font-weight:600}
  .iface-ip{color:var(--muted)}
  .modules{display:grid;grid-template-columns:repeat(3,1fr);gap:20px}
  @media(max-width:900px){.modules{grid-template-columns:1fr 1fr}}
  @media(max-width:600px){.modules{grid-template-columns:1fr}}
  .module-wrap{display:flex;flex-direction:column}
  .module{background:var(--surface);border:1px solid var(--border);border-radius:8px 8px 0 0;padding:24px;text-decoration:none;color:var(--text);transition:all 0.2s;position:relative;overflow:hidden;display:block}
  .module-no-ctrl{border-radius:8px}
  .module::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:var(--module-color,var(--accent));opacity:0.6;transition:opacity 0.2s}
  .module:hover{border-color:var(--module-color,var(--accent));transform:translateY(-2px)}
  .module:hover::before{opacity:1}
  .module-icon{font-size:26px;margin-bottom:10px;display:block}
  .module-title{font-family:'Syne',sans-serif;font-size:17px;font-weight:800;color:var(--module-color,var(--accent));margin-bottom:5px}
  .module-desc{font-size:11px;color:var(--muted);line-height:1.6}
  .module-port{position:absolute;top:12px;right:36px;font-size:10px;color:var(--muted);border:1px solid var(--border);padding:2px 8px;border-radius:3px}
  .module-dot{position:absolute;top:16px;right:14px;width:8px;height:8px;border-radius:50%;animation:pulse 2s infinite}
  .module-tags{display:flex;gap:5px;flex-wrap:wrap;margin-top:10px}
  .tag{font-size:10px;padding:2px 8px;border-radius:3px;background:rgba(255,255,255,0.05);color:var(--muted)}
  .module-controls{display:flex;background:#0d0f14;border:1px solid var(--border);border-top:none;border-radius:0 0 8px 8px;overflow:hidden}
  .mctl{flex:1;padding:8px 4px;font-family:'JetBrains Mono',monospace;font-size:11px;font-weight:600;cursor:pointer;border:none;border-right:1px solid var(--border);transition:background 0.15s;text-align:center}
  .mctl:last-child{border-right:none}
  .btn-go{background:rgba(0,255,136,0.07);color:#00ff88}
  .btn-go:hover{background:rgba(0,255,136,0.18)}
  .btn-stop{background:rgba(255,214,0,0.07);color:#ffd600}
  .btn-stop:hover{background:rgba(255,214,0,0.18)}
  .btn-rm{background:rgba(255,56,96,0.07);color:#ff3860}
  .btn-rm:hover{background:rgba(255,56,96,0.18)}
  .footer{text-align:center;margin-top:40px;font-size:11px;color:var(--muted)}
  .footer span{color:var(--accent)}
</style>
</head>
<body>
<div class="container">
  <div class="hero">
    <div class="hero-label">Management Portal</div>
    <div class="hero-title">1002x<span>OPERATOR</span></div>
    <div class="hero-sub">// NETWORK &amp; SERVICES CONTROL</div>
  </div>

  <div class="status-bar">
    <div class="status-item"><div class="status-dot" style="background:$wan_color"></div>wan-failover: $wan_status</div>
    <div class="status-item"><div class="status-dot" style="background:$samba_color"></div>smbd: $samba_status</div>
    <div class="status-item"><div class="status-dot" style="background:$dhcp_color"></div>isc-dhcp: $dhcp_status</div>
    <div class="status-item"><div class="status-dot" style="background:$ufw_color"></div>ufw: $ufw_status</div>
    <div class="status-item"><div class="status-dot" style="background:$dns_color"></div>dnsmasq: $dns_status</div>
    <div class="status-item"><div class="status-dot" style="background:$([ "$adblock_count" -gt 0 ] && echo '#00ff88' || echo '#64748b')"></div>adblock: $([ "$adblock_count" -gt 0 ] && echo "$adblock_count" || echo "off")</div>
  </div>

  <div class="iface-pills">$wan_ifaces</div>

  <div class="modules">
$(make_card "1002x-dhcp-webui" "8081" "#00e5ff" "⬡" "DHCP" \
  "WAN Failover, Static Routes, DHCP Reservations" \
  "<span class='tag'>WAN</span><span class='tag'>Routing</span><span class='tag'>DHCP</span>" \
  "$dhcp_wa" "$dhcp_wi")
$(make_card "1002x-samba-webui" "8082" "#ff6b35" "⬢" "Samba" \
  "Manage, add, edit and delete file shares" \
  "<span class='tag'>SMB</span><span class='tag'>Shares</span><span class='tag'>Files</span>" \
  "$samba_wa" "$samba_wi")
$(make_card "1002x-ufw-webui" "8083" "#00ff88" "🛡" "UFW" \
  "Firewall rules, policies, logging and diagnostics" \
  "<span class='tag'>Security</span><span class='tag'>Firewall</span><span class='tag'>Rules</span>" \
  "$ufw_wa" "$ufw_wi")
$(make_card "1002x-dns-webui" "8084" "#a78bfa" "◈" "DNS" \
  "dnsmasq: upstream servers, local hosts, zones, adblock" \
  "<span class='tag'>dnsmasq</span><span class='tag'>Hosts</span><span class='tag'>Adblock</span>" \
  "$dns_wa" "$dns_wi")
  </div>

  <div class="footer">
    Auto-refresh every 30s &nbsp;·&nbsp; <span>$(date '+%Y-%m-%d %H:%M:%S')</span>
  </div>
</div>
</body>
</html>
HTML
}

log "Starting 1002xOPERATOR Portal on port $PORT"
log "Open: http://$(ip -4 addr show dev "$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1):$PORT"

FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap "rm -f '$FIFO'" EXIT

while true; do
    handle_request < "$FIFO" | nc -q 1 -l -p "$PORT" > "$FIFO" 2>/dev/null || \
    handle_request < "$FIFO" | nc -l -p "$PORT" > "$FIFO" 2>/dev/null || \
    handle_request < "$FIFO" | nc -l "$PORT" > "$FIFO" 2>/dev/null
done
