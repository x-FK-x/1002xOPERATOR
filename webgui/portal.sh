#!/bin/bash
# portal.sh – 1002xOPERATOR Portal Startseite
# Port 8079

PORT="${1:-8080}"

log() { echo "[portal] $1"; }

handle_request() {
    local method path
    read -r method path _
    path="${path//$'\r'/}"
    method="${method//$'\r'/}"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break
    done

    # Detect own IP
    local HOST_IP LAN_IF DHCP_INSTALLED=0
    LAN_IF=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    [[ -n "$LAN_IF" ]] && DHCP_INSTALLED=1
    HOST_IP=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$HOST_IP" ]] && HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7}' | head -n1)
    [[ -z "$HOST_IP" ]] && HOST_IP=$(hostname -I | awk '{print $1}')

    # Get live status
    local wan_status samba_status dhcp_status
    wan_status=$(systemctl is-active wan-failover 2>/dev/null)
    samba_status=$(systemctl is-active smbd 2>/dev/null)
    dhcp_status=$(systemctl is-active isc-dhcp-server 2>/dev/null)

    local wan_color samba_color dhcp_color
    [[ "$wan_status"   == "active" ]] && wan_color="#00ff88"   || wan_color="#ff3860"
    [[ "$samba_status" == "active" ]] && samba_color="#00ff88" || samba_color="#ff3860"
    [[ "$dhcp_status"  == "active" ]] && dhcp_color="#00ff88"  || dhcp_color="#ff3860"

    # WAN interfaces quick status
    local wan_ifaces=""
    local priority_file="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
    local state_file="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
    local iface_list=""
    if [[ -f "$priority_file" ]]; then
        iface_list=$(tail -n1 "$priority_file")
    else
        # No priority file – show all interfaces with IPs except loopback
        iface_list=$(ip -o -4 addr show | awk '{print $2}' | grep -v '^lo$' | tr '
' ' ')
    fi
    for iface in $iface_list; do
        local ip state suppressed dot_color label
        ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet/ {print $2}' | head -n1)
        state=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "?")
        grep -q "^SUPPRESSED $iface " "$state_file" 2>/dev/null && suppressed=1 || suppressed=0
        [[ "$iface" == "$LAN_IF" ]] && label="LAN" || label="WAN"
        if [[ "$suppressed" -eq 1 ]]; then dot_color="#ff3860"
        elif [[ "$state" == "up" ]]; then dot_color="#00ff88"
        else dot_color="#ff3860"; fi
        wan_ifaces+="<div class='iface-pill'><span class='dot' style='background:$dot_color'></span><span class='iface-name'>$iface</span><span class='iface-ip'>${ip:-no ip}</span><span class='iface-ip' style='color:#64748b;margin-left:4px'>[$label]</span></div>"
    done

    printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
    cat <<HTML
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>1002xOPERATOR</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Syne:wght@400;700;800;900&display=swap');
  :root {
    --bg: #0a0c10;
    --surface: #111318;
    --border: #1e2230;
    --accent: #00e5ff;
    --accent2: #ff6b35;
    --green: #00ff88;
    --red: #ff3860;
    --text: #e2e8f0;
    --muted: #64748b;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'JetBrains Mono', monospace;
    min-height: 100vh;
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    padding: 40px 20px;
  }
  body::before {
    content: '';
    position: fixed; inset: 0;
    background: repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0,229,255,0.012) 2px, rgba(0,229,255,0.012) 4px);
    pointer-events: none;
  }
  /* grid background */
  body::after {
    content: '';
    position: fixed; inset: 0;
    background-image:
      linear-gradient(rgba(0,229,255,0.03) 1px, transparent 1px),
      linear-gradient(90deg, rgba(0,229,255,0.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
  }
  .container { position: relative; z-index: 1; width: 100%; max-width: 900px; }
  .hero { text-align: center; margin-bottom: 60px; }
  .hero-label {
    font-size: 11px; letter-spacing: 4px;
    text-transform: uppercase; color: var(--muted);
    margin-bottom: 12px;
  }
  .hero-title {
    font-family: 'Syne', sans-serif;
    font-size: clamp(42px, 8vw, 80px);
    font-weight: 900;
    line-height: 1;
    color: var(--accent);
    letter-spacing: -2px;
  }
  .hero-title span { color: var(--accent2); }
  .hero-sub {
    font-size: 12px; color: var(--muted);
    margin-top: 12px; letter-spacing: 2px;
  }
  .status-bar {
    display: flex; gap: 20px; justify-content: center; flex-wrap: wrap;
    margin-bottom: 48px;
  }
  .status-item {
    display: flex; align-items: center; gap: 8px;
    font-size: 12px; color: var(--muted);
  }
  .status-dot {
    width: 8px; height: 8px; border-radius: 50%;
    animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%,100%{ opacity:1; } 50%{ opacity:0.4; }
  }
  .iface-pills { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; margin-bottom: 48px; }
  .iface-pill {
    display: flex; align-items: center; gap: 8px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 20px;
    padding: 6px 14px;
    font-size: 12px;
  }
  .dot { width: 7px; height: 7px; border-radius: 50%; }
  .iface-name { color: var(--accent); font-weight: 600; }
  .iface-ip { color: var(--muted); }
  .modules { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  @media(max-width:600px) { .modules { grid-template-columns: 1fr; } }
  .module {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 28px;
    text-decoration: none;
    color: var(--text);
    transition: all 0.2s;
    position: relative;
    overflow: hidden;
  }
  .module::before {
    content: '';
    position: absolute; top: 0; left: 0; right: 0; height: 2px;
    background: var(--module-color, var(--accent));
    opacity: 0.6;
    transition: opacity 0.2s;
  }
  .module:hover { border-color: var(--module-color, var(--accent)); transform: translateY(-2px); }
  .module:hover::before { opacity: 1; }
  .module-icon {
    font-size: 28px; margin-bottom: 12px;
    display: block;
  }
  .module-title {
    font-family: 'Syne', sans-serif;
    font-size: 18px; font-weight: 800;
    color: var(--module-color, var(--accent));
    margin-bottom: 6px;
  }
  .module-desc { font-size: 12px; color: var(--muted); line-height: 1.6; }
  .module-port {
    position: absolute; top: 16px; right: 16px;
    font-size: 10px; color: var(--muted);
    border: 1px solid var(--border);
    padding: 2px 8px; border-radius: 3px;
  }
  .module-tags { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 12px; }
  .tag {
    font-size: 10px; padding: 2px 8px; border-radius: 3px;
    background: rgba(255,255,255,0.05);
    color: var(--muted);
  }
  .footer { text-align: center; margin-top: 48px; font-size: 11px; color: var(--muted); }
  .footer span { color: var(--accent); }
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
    <div class="status-item">
      <div class="status-dot" style="background:$wan_color"></div>
      wan-failover: $wan_status
    </div>
    <div class="status-item">
      <div class="status-dot" style="background:$samba_color"></div>
      smbd: $samba_status
    </div>
$(if [[ "$DHCP_INSTALLED" -eq 1 ]]; then echo "
    <div class=\"status-item\">
      <div class=\"status-dot\" style=\"background:$dhcp_color\"></div>
      isc-dhcp: $dhcp_status
    </div>"; fi)
  </div>

  <div class="iface-pills">
    $wan_ifaces
  </div>

  <div class="modules">
$(if [[ "$DHCP_INSTALLED" -eq 1 ]]; then echo "
    <a href=\"http://$HOST_IP:8081\" class=\"module\" style=\"--module-color: #00e5ff\">
      <span class=\"module-port\">:8081</span>
      <span class=\"module-icon\">⬡</span>
      <div class=\"module-title\">DHCP</div>
      <div class=\"module-desc\">WAN Failover, Static Routes, DHCP Reservations, DNS Settings</div>
      <div class=\"module-tags\">
        <span class=\"tag\">WAN</span>
        <span class=\"tag\">Routing</span>
        <span class=\"tag\">DHCP</span>
        <span class=\"tag\">DNS</span>
      </div>
    </a>"; fi)

    <a href="http://$HOST_IP:8082" class="module" style="--module-color: #ff6b35">
      <span class="module-port">:8081</span>
      <span class="module-icon">⬢</span>
      <div class="module-title">Samba</div>
      <div class="module-desc">Manage, add, edit and delete file shares</div>
      <div class="module-tags">
        <span class="tag">SMB</span>
        <span class="tag">Shares</span>
        <span class="tag">Files</span>
      </div>
    </a>
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
log "Open: http://$(ip -4 addr show dev $(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2) 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1):$PORT"

FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap "rm -f '$FIFO'" EXIT

while true; do
    handle_request < "$FIFO" | nc -q 1 -l -p "$PORT" > "$FIFO" 2>/dev/null ||     handle_request < "$FIFO" | nc -l -p "$PORT" > "$FIFO" 2>/dev/null ||     handle_request < "$FIFO" | nc -l "$PORT" > "$FIFO" 2>/dev/null
done
