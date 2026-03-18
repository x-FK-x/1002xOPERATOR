#!/bin/bash
# dhcp.sh – 1002xOPERATOR Network Web Interface
# WAN, Static Routes, DHCP Reservations, DNS
# Usage: bash network.sh [port]  (default: 8081)

PORT="${1:-8081}"
SETTINGS="/etc/1002xOPERATOR/dhcp/settings"
DHCP_CONF="/etc/dhcp/dhcpd.conf"
STATIC_CONF="/etc/dhcp/static-hosts.conf"
LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
FAILOVER_LOG="/var/log/wan-failover.log"
STATE_FILE="$SETTINGS/wan-failover.state"
STATIC_ROUTES="$SETTINGS/static-routes.conf"
PRIORITY_FILE="$SETTINGS/wan-priority.list"

log() { echo "[dhcp-webui] $1"; }

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

get_post_value() {
    local body="$1" key="$2"
    local val
    val=$(echo "$body" | tr '&' '\n' | grep "^${key}=" | head -n1 | cut -d'=' -f2-)
    urldecode "$val"
}

html_page() {
    local title="$1" body="$2"
    local HOST_IP
    LAN_IF=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    HOST_IP=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$HOST_IP" ]] && HOST_IP=$(hostname -I | awk '{print $1}')
    cat <<HTML
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title – 1002xOPERATOR</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Syne:wght@400;700;800&display=swap');
  :root{--bg:#0a0c10;--surface:#111318;--border:#1e2230;--accent:#00e5ff;--accent2:#ff6b35;--green:#00ff88;--red:#ff3860;--yellow:#ffd600;--text:#e2e8f0;--muted:#64748b;--radius:6px}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:13px;min-height:100vh}
  body::before{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,229,255,0.015) 2px,rgba(0,229,255,0.015) 4px);pointer-events:none;z-index:9999}
  header{display:flex;align-items:center;gap:16px;padding:16px 24px;background:var(--surface);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:100}
  header .logo{font-family:'Syne',sans-serif;font-weight:800;font-size:18px;color:var(--accent);letter-spacing:-0.5px;text-decoration:none}
  header .logo span{color:var(--accent2)}
  nav{display:flex;gap:4px;margin-left:auto}
  nav a{padding:6px 14px;color:var(--muted);text-decoration:none;border-radius:var(--radius);font-size:12px;transition:all 0.15s;border:1px solid transparent}
  nav a:hover,nav a.active{color:var(--accent);border-color:var(--accent);background:rgba(0,229,255,0.05)}
  nav a.home-link{color:var(--accent2);border-color:var(--accent2);background:rgba(255,107,53,0.05)}
  nav a.home-link:hover{background:rgba(255,107,53,0.12)}
  main{max-width:1100px;margin:0 auto;padding:32px 24px}
  h1{font-family:'Syne',sans-serif;font-size:22px;font-weight:800;color:var(--accent);margin-bottom:24px;display:flex;align-items:center;gap:10px}
  h1::before{content:'//';color:var(--accent2);font-family:'JetBrains Mono',monospace}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:20px;margin-bottom:20px}
  .card h2{font-family:'Syne',sans-serif;font-size:14px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid var(--border)}
  table{width:100%;border-collapse:collapse}
  th{text-align:left;padding:8px 12px;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:1px;border-bottom:1px solid var(--border)}
  td{padding:10px 12px;border-bottom:1px solid rgba(30,34,48,0.5)}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:rgba(255,255,255,0.02)}
  .badge{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:600}
  .badge-green{background:rgba(0,255,136,0.15);color:var(--green)}
  .badge-red{background:rgba(255,56,96,0.15);color:var(--red)}
  .badge-yellow{background:rgba(255,214,0,0.15);color:var(--yellow)}
  .badge-blue{background:rgba(0,229,255,0.15);color:var(--accent)}
  .form-row{display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap;margin-top:16px}
  .form-group{display:flex;flex-direction:column;gap:4px}
  .form-group label{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:0.5px}
  input[type=text],select{background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);color:var(--text);padding:8px 12px;font-family:'JetBrains Mono',monospace;font-size:13px;outline:none;transition:border-color 0.15s;min-width:180px}
  input:focus,select:focus{border-color:var(--accent)}
  button,.btn{padding:8px 18px;border-radius:var(--radius);font-family:'JetBrains Mono',monospace;font-size:12px;font-weight:600;cursor:pointer;border:1px solid;transition:all 0.15s;text-decoration:none;display:inline-block}
  .btn-primary{background:rgba(0,229,255,0.1);border-color:var(--accent);color:var(--accent)}
  .btn-primary:hover{background:rgba(0,229,255,0.2)}
  .btn-danger{background:rgba(255,56,96,0.1);border-color:var(--red);color:var(--red)}
  .btn-danger:hover{background:rgba(255,56,96,0.2)}
  .btn-success{background:rgba(0,255,136,0.1);border-color:var(--green);color:var(--green)}
  .btn-success:hover{background:rgba(0,255,136,0.2)}
  pre,.logbox{background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);padding:16px;overflow-x:auto;overflow-y:auto;max-height:400px;font-size:12px;line-height:1.6;color:#94a3b8;white-space:pre-wrap;word-break:break-all}
  .alert{padding:12px 16px;border-radius:var(--radius);margin-bottom:16px;font-size:12px}
  .alert-ok{background:rgba(0,255,136,0.1);border:1px solid var(--green);color:var(--green)}
  .alert-err{background:rgba(255,56,96,0.1);border:1px solid var(--red);color:var(--red)}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
  .iface-row{display:flex;gap:16px;align-items:center;flex-wrap:wrap}
  .iface-block{flex:1;min-width:200px;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);padding:16px}
  .iface-name{font-family:'Syne',sans-serif;font-size:16px;font-weight:800;color:var(--accent)}
  .iface-detail{color:var(--muted);font-size:12px;margin-top:4px;line-height:1.8}
  .mono{font-family:'JetBrains Mono',monospace}
  @media(max-width:700px){.grid2{grid-template-columns:1fr}}
</style>
</head>
<body>
<header>
  <a class="logo" href="/">1002x<span>OPERATOR</span></a>
  <nav>
    <a href="http://$HOST_IP:8080" class="home-link">⌂ Portal</a>
    <a href="/" $([ "$title" = "WAN Status" ] && echo 'class="active"')>⬡ WAN</a>
    <a href="/routes" $([ "$title" = "Static Routes" ] && echo 'class="active"')>⇄ Routes</a>
    <a href="/reservations" $([ "$title" = "Reservationen" ] && echo 'class="active"')>⬢ DHCP</a>
    <a href="/dns" $([ "$title" = "DNS" ] && echo 'class="active"')>◈ DNS</a>
  </nav>
</header>
<main>
$body
</main>
</body>
</html>
HTML
}

# ---- WAN page ----
page_wan() {
    local body ifaces=""
    local wan_list=""
    [[ -f "$PRIORITY_FILE" ]] && wan_list=$(tail -n1 "$PRIORITY_FILE")

    # LAN/DHCP interface
    local lan_if lan_block=""
    lan_if=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    if [[ -n "$lan_if" ]]; then
        local lan_ip lan_state lan_badge
        lan_ip=$(ip -4 addr show dev "$lan_if" 2>/dev/null | awk '/inet/ {print $2}' | head -n1)
        lan_state=$(cat /sys/class/net/$lan_if/operstate 2>/dev/null || echo "unknown")
        [[ "$lan_state" == "up" ]] && lan_badge='<span class="badge badge-blue">LAN</span>' || lan_badge='<span class="badge badge-red">DOWN</span>'
        lan_block="<div class='iface-block'><div class='iface-name'>$lan_if $lan_badge</div><div class='iface-detail'>IP: <span class='mono'>${lan_ip:-–}</span><br>State: <span class='mono'>$lan_state</span><br>Role: <span class='mono'>DHCP Server</span></div></div>"
    fi

    # WAN interfaces
    local wan_block=""
    for iface in $wan_list; do
        local ip gw state badge
        ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet/ {print $2}' | head -n1)
        gw=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3}' | head -n1)
        state=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
        local metric
        metric=$(ip route show default dev "$iface" 2>/dev/null | awk '/metric/ {for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}' | head -n1)
        grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null             && badge='<span class="badge badge-red">SUPPRESSED</span>'             || { [[ "$state" == "up" ]] && badge='<span class="badge badge-green">UP</span>' || badge='<span class="badge badge-red">DOWN</span>'; }
        wan_block+="<div class='iface-block'><div class='iface-name'>$iface $badge</div><div class='iface-detail'>IP: <span class='mono'>${ip:-–}</span><br>GW: <span class='mono'>${gw:-–}</span><br>Metric: <span class='mono'>${metric:-–}</span><br>State: <span class='mono'>$state</span></div></div>"
    done
    local svc_status svc_badge
    svc_status=$(systemctl is-active wan-failover 2>/dev/null)
    [[ "$svc_status" == "active" ]] && svc_badge='<span class="badge badge-green">active</span>' || svc_badge='<span class="badge badge-red">'$svc_status'</span>'
    body="<h1>WAN Status</h1>
<div class='card'><h2>Service wan-failover $svc_badge</h2>
<div style='display:flex;gap:10px;flex-wrap:wrap'>
<form method='POST' action='/wan/action'><input type='hidden' name='action' value='restart'><button class='btn btn-primary'>↺ Restart</button></form>
<form method='POST' action='/wan/action'><input type='hidden' name='action' value='stop'><button class='btn btn-danger'>■ Stop</button></form>
<form method='POST' action='/wan/action'><input type='hidden' name='action' value='start'><button class='btn btn-success'>▶ Start</button></form>
<form method='POST' action='/wan/action'><input type='hidden' name='action' value='clear_state'><button class='btn btn-danger'>✕ Clear state</button></form>
</div></div>
<div class='card'><h2>LAN Interface</h2><div class='iface-row'>$lan_block</div></div>
<div class='card'><h2>WAN Interfaces</h2><div class='iface-row'>$wan_block</div></div>
<div class='grid2'>
<div class='card'><h2>Routing Table</h2><pre>$(ip route 2>/dev/null)</pre></div>
<div class='card'><h2>Failover State</h2><pre>$(cat "$STATE_FILE" 2>/dev/null || echo "(empty)")</pre></div>
</div>
<div class='card'><h2>Failover Log (last 60 lines)</h2><pre class='logbox'>$(tail -n60 "$FAILOVER_LOG" 2>/dev/null | tac || echo "(no log)")</pre></div>"
    html_page "WAN Status" "$body"
}

# ---- Routes page ----
page_routes() {
    local msg="$1" body wan_list=""
    [[ -f "$PRIORITY_FILE" ]] && wan_list=$(tail -n1 "$PRIORITY_FILE")
    local select_opts=""
    for i in $wan_list; do select_opts+="<option value='$i'>$i</option>"; done
    body="<h1>Static Routes</h1>${msg}
<div class='card'><h2>Add route</h2>
<form method='POST' action='/routes/add'><div class='form-row'>
<div class='form-group'><label>Destination</label><input type='text' name='dest' placeholder='178.15.44.66 oder 10.5.0.0/24'></div>
<div class='form-group'><label>Interface</label><select name='iface'>$select_opts</select></div>
<div class='form-group'><label>Gateway (optional)</label><input type='text' name='gw' placeholder='auto'></div>
<button class='btn btn-primary' type='submit'>+ Add</button>
</div></form></div>
<div class='card'><h2>Saved routes</h2>"
    if [[ -f "$STATIC_ROUTES" && -s "$STATIC_ROUTES" ]]; then
        body+="<table><tr><th>#</th><th>Destination</th><th>Interface</th><th>Gateway</th><th>Kernel</th><th></th></tr>"
        local idx=1
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            read -r dest iface gw <<< "$line"
            local kb
            ip route show "$dest" dev "$iface" &>/dev/null && kb='<span class="badge badge-green">aktiv</span>' || kb='<span class="badge badge-yellow">fehlt</span>'
            body+="<tr><td>$idx</td><td class='mono'>$dest</td><td class='mono'>$iface</td><td class='mono'>$gw</td><td>$kb</td><td style='display:flex;gap:6px'>
<form method='POST' action='/routes/delete'><input type='hidden' name='line' value='$idx'><button class='btn btn-danger' type='submit'>✕</button></form>
<form method='POST' action='/routes/apply'><input type='hidden' name='line' value='$idx'><button class='btn btn-primary' type='submit'>↺</button></form>
</td></tr>"
            idx=$((idx+1))
        done < "$STATIC_ROUTES"
        body+="</table>"
    else
        body+="<p style='color:var(--muted)'>No saved routes.</p>"
    fi
    body+="</div><div class='card'><h2>Kernel routes</h2><pre>$(ip route 2>/dev/null)</pre></div>"
    html_page "Static Routes" "$body"
}

# ---- Reservations page ----
page_reservations() {
    local msg="$1" body=""
    body="<h1>DHCP Reservations</h1>${msg}
<div class='card'><h2>Existing reservations</h2>"
    if [[ -f "$STATIC_CONF" && -s "$STATIC_CONF" ]]; then
        body+="<table><tr><th>Hostname</th><th>MAC</th><th>IP</th><th></th></tr>"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local host mac ip
            host=$(echo "$line" | grep -oP '(?<=host )\S+')
            mac=$(echo "$line"  | grep -oP '(?<=hardware ethernet )[^;]+')
            ip=$(echo "$line"   | grep -oP '(?<=fixed-address )[^;]+')
            [[ -z "$host" ]] && continue
            body+="<tr><td class='mono'>$host</td><td class='mono'>$mac</td><td class='mono'>$ip</td>
<td><form method='POST' action='/reservations/delete'><input type='hidden' name='mac' value='$mac'><button class='btn btn-danger' type='submit'>✕</button></form></td></tr>"
        done < "$STATIC_CONF"
        body+="</table>"
    else
        body+="<p style='color:var(--muted)'>No reservations.</p>"
    fi
    body+="</div><div class='card'><h2>Active leases</h2>"
    if [[ -f "$LEASE_FILE" ]]; then
        body+="<table><tr><th>IP</th><th>MAC</th><th>Hostname</th><th></th></tr>"
        local cur_ip cur_mac cur_host
        while IFS= read -r line; do
            [[ $line =~ ^lease\ ([0-9.]+) ]]            && cur_ip="${BASH_REMATCH[1]}"
            [[ $line =~ hardware\ ethernet\ ([a-fA-F0-9:]+) ]] && cur_mac="${BASH_REMATCH[1]}"
            [[ $line =~ client-hostname\ \"([^\"]+)\" ]] && cur_host="${BASH_REMATCH[1]}"
            if [[ $line =~ ^\} && -n "$cur_mac" && -n "$cur_ip" ]]; then
                if ! grep -q "$cur_mac" "$STATIC_CONF" 2>/dev/null; then
                    local h="${cur_host:-$cur_mac}"
                    body+="<tr><td class='mono'>$cur_ip</td><td class='mono'>$cur_mac</td><td class='mono'>$h</td>
<td><form method='POST' action='/reservations/add'><input type='hidden' name='ip' value='$cur_ip'><input type='hidden' name='mac' value='$cur_mac'><input type='hidden' name='host' value='$h'><button class='btn btn-success' type='submit'>+ Reserve</button></form></td></tr>"
                fi
                cur_ip=""; cur_mac=""; cur_host=""
            fi
        done < "$LEASE_FILE"
        body+="</table>"
    else
        body+="<p style='color:var(--muted)'>Lease file not found.</p>"
    fi
    body+="</div><div class='card'><h2>Add manually</h2>
<form method='POST' action='/reservations/add'><div class='form-row'>
<div class='form-group'><label>MAC</label><input type='text' name='mac' placeholder='aa:bb:cc:dd:ee:ff'></div>
<div class='form-group'><label>IP</label><input type='text' name='ip' placeholder='10.2.0.100'></div>
<div class='form-group'><label>Hostname</label><input type='text' name='host' placeholder='my-device'></div>
<button class='btn btn-primary' type='submit'>+ Add</button>
</div></form></div>"
    html_page "Reservationen" "$body"
}

# ---- DNS page ----
page_dns() {
    local msg="$1"
    local cur_dns cur_domain
    cur_dns=$(awk '/option domain-name-servers/{gsub(/.*option domain-name-servers /,"");gsub(/;/,"");print}' "$DHCP_CONF" 2>/dev/null)
    cur_domain=$(awk '/option domain-name /{gsub(/.*option domain-name /,"");gsub(/;/,"");gsub(/"/,"");print}' "$DHCP_CONF" 2>/dev/null)
    local body="<h1>DNS Settings</h1>${msg}
<div class='grid2'>
<div class='card'><h2>DNS Servers</h2>
<form method='POST' action='/dns/save'><div class='form-group' style='margin-bottom:12px'><label>DNS Servers (kommagetrennt)</label>
<input type='text' name='dns' value='$cur_dns' style='width:100%'></div>
<button class='btn btn-primary' type='submit'>Save</button></form></div>
<div class='card'><h2>DNS Domain</h2>
<form method='POST' action='/dns/domain'><div class='form-group' style='margin-bottom:12px'><label>Domain</label>
<input type='text' name='domain' value='$cur_domain' style='width:100%'></div>
<button class='btn btn-primary' type='submit'>Save</button></form></div>
</div>
<div class='card'><h2>Current configuration</h2><pre>$(grep -E 'domain-name|domain-name-servers' "$DHCP_CONF" 2>/dev/null | head -10)</pre></div>"
    html_page "DNS" "$body"
}

# ---- HTTP helpers ----
http_200()      { printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"; echo "$1"; }
http_redirect() { printf "HTTP/1.1 302 Found\r\nLocation: $1\r\nConnection: close\r\n\r\n"; }
alert_ok()      { echo "<div class='alert alert-ok'>✓ $1</div>"; }
alert_err()     { echo "<div class='alert alert-err'>✗ $1</div>"; }

# ---- Request handler ----
handle_request() {
    local method path content_length body_raw
    read -r method path _
    path="${path//$'\r'/}"
    method="${method//$'\r'/}"
    while IFS= read -r line; do
        line="${line%$'\r'}"; [[ -z "$line" ]] && break
        [[ "$line" =~ ^Content-Length:\ ([0-9]+) ]] && content_length="${BASH_REMATCH[1]}"
    done
    [[ "$method" == "POST" && -n "$content_length" && "$content_length" -gt 0 ]] && body_raw=$(dd bs=1 count="$content_length" 2>/dev/null)
    path="${path%%\?*}"

    case "$method $path" in
    "GET /")             http_200 "$(page_wan)" ;;
    "POST /wan/action")
        local action; action=$(get_post_value "$body_raw" "action")
        case "$action" in
            restart)     systemctl restart wan-failover ;;
            stop)        systemctl stop    wan-failover ;;
            start)       systemctl start   wan-failover ;;
            clear_state) truncate -s 0 "$STATE_FILE" ;;
        esac; http_redirect "/" ;;
    "GET /routes")       http_200 "$(page_routes)" ;;
    "POST /routes/add")
        local dest iface gw
        dest=$(get_post_value "$body_raw" "dest"); iface=$(get_post_value "$body_raw" "iface"); gw=$(get_post_value "$body_raw" "gw")
        [[ -z "$dest" || -z "$iface" ]] && { http_200 "$(page_routes "$(alert_err "Destination und Interface erforderlich")")"; return; }
        [[ -z "$gw" ]] && gw=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3}' | head -n1)
        [[ -z "$gw" ]] && { http_200 "$(page_routes "$(alert_err "No gateway for $iface")")"; return; }
        ip route replace "$dest" via "$gw" dev "$iface" 2>/dev/null
        grep -qxF "$dest $iface $gw" "$STATIC_ROUTES" 2>/dev/null || echo "$dest $iface $gw" >> "$STATIC_ROUTES"
        http_200 "$(page_routes "$(alert_ok "Route $dest via $iface ($gw) hinzugefügt")")" ;;
    "POST /routes/delete")
        local ln; ln=$(get_post_value "$body_raw" "line")
        if [[ "$ln" =~ ^[0-9]+$ ]]; then
            local dl; dl=$(sed -n "${ln}p" "$STATIC_ROUTES"); read -r dest iface gw <<< "$dl"
            ip route del "$dest" dev "$iface" 2>/dev/null || true
            sed -i "${ln}d" "$STATIC_ROUTES"
            http_200 "$(page_routes "$(alert_ok "Route deleted")")"
        else http_200 "$(page_routes "$(alert_err "Invalid line")")"; fi ;;
    "POST /routes/apply")
        local ln; ln=$(get_post_value "$body_raw" "line")
        [[ "$ln" =~ ^[0-9]+$ ]] && { local al; al=$(sed -n "${ln}p" "$STATIC_ROUTES"); read -r dest iface gw <<< "$al"; ip route replace "$dest" via "$gw" dev "$iface" 2>/dev/null; http_200 "$(page_routes "$(alert_ok "Route $dest applied")")"; } || http_redirect "/routes" ;;
    "GET /reservations") http_200 "$(page_reservations)" ;;
    "POST /reservations/add")
        local mac ip host
        mac=$(get_post_value "$body_raw" "mac"); ip=$(get_post_value "$body_raw" "ip"); host=$(get_post_value "$body_raw" "host")
        host="${host//[^a-zA-Z0-9_-]/}"; [[ -z "$host" ]] && host="host${RANDOM}"
        [[ -z "$mac" || -z "$ip" ]] && { http_200 "$(page_reservations "$(alert_err "MAC and IP required")")"; return; }
        grep -q "$mac" "$STATIC_CONF" 2>/dev/null && { http_200 "$(page_reservations "$(alert_err "MAC already reserved")")"; return; }
        touch "$STATIC_CONF"
        echo "host $host { hardware ethernet $mac; fixed-address $ip; }" >> "$STATIC_CONF"
        grep -q 'include.*static-hosts.conf' /etc/dhcp/dhcpd.conf 2>/dev/null || echo 'include "/etc/dhcp/static-hosts.conf";' >> /etc/dhcp/dhcpd.conf
        systemctl restart isc-dhcp-server 2>/dev/null || true
        http_200 "$(page_reservations "$(alert_ok "Reservation for $host ($ip) saved")")" ;;
    "POST /reservations/delete")
        local mac; mac=$(get_post_value "$body_raw" "mac")
        [[ -n "$mac" && -f "$STATIC_CONF" ]] && { grep -v "$mac" "$STATIC_CONF" > "${STATIC_CONF}.tmp" && mv "${STATIC_CONF}.tmp" "$STATIC_CONF"; [[ ! -s "$STATIC_CONF" ]] && sed -i '/include.*static-hosts.conf/d' /etc/dhcp/dhcpd.conf; systemctl restart isc-dhcp-server 2>/dev/null || true; http_200 "$(page_reservations "$(alert_ok "Reservation deleted")")"; } || http_redirect "/reservations" ;;
    "GET /dns")          http_200 "$(page_dns)" ;;
    "POST /dns/save")
        local dns; dns=$(get_post_value "$body_raw" "dns")
        [[ -n "$dns" ]] && { cp "$DHCP_CONF" "${DHCP_CONF}.bak"; awk -v d="$dns" '/option domain-name-servers/{print "    option domain-name-servers " d ";"; next}{print}' "$DHCP_CONF" > "${DHCP_CONF}.tmp" && mv "${DHCP_CONF}.tmp" "$DHCP_CONF"; systemctl restart isc-dhcp-server 2>/dev/null || true; http_200 "$(page_dns "$(alert_ok "DNS auf $dns gesetzt")")"; } || http_200 "$(page_dns "$(alert_err "No DNS specified")")" ;;
    "POST /dns/domain")
        local domain; domain=$(get_post_value "$body_raw" "domain")
        [[ -n "$domain" ]] && { cp "$DHCP_CONF" "${DHCP_CONF}.bak"; awk -v d="$domain" '/option domain-name /{print "    option domain-name \"" d "\";"; next}{print}' "$DHCP_CONF" > "${DHCP_CONF}.tmp" && mv "${DHCP_CONF}.tmp" "$DHCP_CONF"; systemctl restart isc-dhcp-server 2>/dev/null || true; http_200 "$(page_dns "$(alert_ok "Domain auf $domain gesetzt")")"; } || http_200 "$(page_dns "$(alert_err "No domain specified")")" ;;
    *) printf "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n404" ;;
    esac
}

log "Starting DHCP WebUI on port $PORT"
log "Open: http://$(ip -4 addr show dev $(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2) 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1):$PORT"

FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap "rm -f '$FIFO'" EXIT

while true; do
    handle_request < "$FIFO" | nc -q 1 -l -p "$PORT" > "$FIFO" 2>/dev/null ||     handle_request < "$FIFO" | nc -l -p "$PORT" > "$FIFO" 2>/dev/null ||     handle_request < "$FIFO" | nc -l "$PORT" > "$FIFO" 2>/dev/null
done
