#!/bin/bash
# ── Access Control ─────────────────────────────────────────────────────────────
# Requires socat: it sets SOCAT_PEERADDR for each connection. Without socat the
# peer address is unknown and access control is skipped (see main).
_AC_CONF="/etc/1002xOPERATOR/webgui/access.conf"
_ip_in_cidr() {
    local ip="$1" cidr="$2" net bits IFS=.
    net="${cidr%/*}"; bits="${cidr#*/}"; [[ "$bits" == "$cidr" ]] && bits=32
    read -r i1 i2 i3 i4 <<< "$ip"; read -r n1 n2 n3 n4 <<< "$net"
    local ip_int=$(( (i1<<24)|(i2<<16)|(i3<<8)|i4 ))
    local net_int=$(( (n1<<24)|(n2<<16)|(n3<<8)|n4 ))
    local mask=$(( 0xFFFFFFFF << (32-bits) & 0xFFFFFFFF ))
    (( (ip_int & mask) == (net_int & mask) ))
}
ac_check() {
    [[ ! -f "$_AC_CONF" ]] && return 0
    local _ip="${SOCAT_PEERADDR:-}"; _ip="${_ip#::ffff:}"; [[ -z "$_ip" ]] && return 0
    local _default; _default=$(grep -E '^DEFAULT=' "$_AC_CONF" | tail -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
    [[ -z "$_default" ]] && _default="allow"
    local _allowed=()
    while IFS= read -r _l; do
        _l="${_l%$'\r'}"
        [[ "$_l" =~ ^#|^DEFAULT|^$ ]] && continue
        _allowed+=("$_l")
    done < "$_AC_CONF"
    if [[ ${#_allowed[@]} -eq 0 ]]; then [[ "$_default" == "allow" ]] && return 0; else
        for _cidr in "${_allowed[@]}"; do _ip_in_cidr "$_ip" "$_cidr" && return 0; done
    fi
    printf "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
    printf '<html><body style="background:#0a0c10;color:#ff3860;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh"><div style="text-align:center"><div style="font-size:48px;font-weight:900">&#9940; 403</div><div style="color:#64748b">Access denied.</div></div></body></html>'
    return 1
}
# ───────────────────────────────────────────────────────────────────────────────

# dhcp.sh – 1002xOPERATOR Network Web Interface
# WAN, Static Routes, DHCP Reservations, DNS
# Usage: bash dhcp.sh [port]   (default: 8081)

SETTINGS="/etc/1002xOPERATOR/dhcp/settings"
DHCP_CONF="/etc/dhcp/dhcpd.conf"
STATIC_CONF="/etc/dhcp/static-hosts.conf"
INCLUDE_LINE="include \"$STATIC_CONF\";"
LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
FAILOVER_LOG="/var/log/wan-failover.log"
STATE_FILE="$SETTINGS/wan-failover.state"
STATIC_ROUTES="$SETTINGS/static-routes.conf"
PRIORITY_FILE="$SETTINGS/wan-priority.list"
BACKUP_KEEP=10

# Logs go to stderr: stdout is the HTTP response and must stay clean
log() { echo "[dhcp-webui] $1" >&2; }

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

get_post_value() {
    local body="$1" key="$2"
    local val
    val=$(echo "$body" | tr '&' '\n' | grep "^${key}=" | head -n1 | cut -d'=' -f2-)
    urldecode "$val"
}

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    s="${s//\"/&quot;}"; s="${s//\'/&#39;}"
    printf '%s' "$s"
}

# ---- Validation ----
valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

valid_mac()      { [[ ${1,,} =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; }
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
valid_domain()   { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; }
valid_iface()    { [[ $1 =~ ^[a-zA-Z0-9._-]{1,15}$ ]] && ip link show dev "$1" &>/dev/null; }

# Accepts a plain IPv4 address or IPv4 with prefix length (0-32)
valid_dest() {
    local ip=${1%/*} prefix=""
    [[ $1 == */* ]] && prefix=${1#*/}
    valid_ipv4 "$ip" || return 1
    [[ -z $prefix ]] && return 0
    [[ $prefix =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix <= 32 ))
}

valid_dns_list() {
    local ip
    local -a ips
    IFS=',' read -ra ips <<< "$1"
    (( ${#ips[@]} > 0 )) || return 1
    for ip in "${ips[@]}"; do
        valid_ipv4 "$ip" || return 1
    done
    return 0
}

sanitize_hostname() {
    local hn="${1//[^a-zA-Z0-9-]/}"
    [[ -z $hn ]] && hn="host$RANDOM"
    echo "$hn"
}

# ---- DHCP config handling (same logic as the CLI scripts) ----
make_backup() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    BK_STATIC="/etc/dhcp/static-hosts.$ts.bak"
    BK_DHCPD="/etc/dhcp/dhcpd.conf.$ts.bak"
    cp "$STATIC_CONF" "$BK_STATIC"
    cp "$DHCP_CONF" "$BK_DHCPD"
    ls -1t /etc/dhcp/static-hosts.*.bak 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f
    ls -1t /etc/dhcp/dhcpd.conf.*.bak 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f
}

rollback() {
    cp "$BK_STATIC" "$STATIC_CONF"
    cp "$BK_DHCPD" "$DHCP_CONF"
    log "[WARN] Changes rolled back to backup"
}

sync_include() {
    local tmp
    if [[ -s $STATIC_CONF ]]; then
        grep -qF "$INCLUDE_LINE" "$DHCP_CONF" || echo "$INCLUDE_LINE" >> "$DHCP_CONF"
    else
        tmp=$(mktemp)
        grep -vF "$INCLUDE_LINE" "$DHCP_CONF" > "$tmp" || true
        cat "$tmp" > "$DHCP_CONF"
        rm -f "$tmp"
    fi
}

# Validates the config and restarts the service; rolls back on any failure
apply_dhcp() {
    sync_include
    if ! dhcpd -t -cf "$DHCP_CONF" >/dev/null 2>&1; then
        log "[ERROR] dhcpd configuration test failed"
        rollback
        return 1
    fi
    if ! systemctl restart isc-dhcp-server 2>/dev/null; then
        log "[ERROR] DHCP server restart failed"
        rollback
        systemctl restart isc-dhcp-server 2>/dev/null || true
        return 1
    fi
    return 0
}

# Writes dhcpd.conf via a temp file in the same directory, then moves it into place
write_dhcp_conf() {
    local tmp
    tmp=$(mktemp "$(dirname "$DHCP_CONF")/.dhcpd.conf.XXXXXX") || return 1
    if sed -E "$1" "$DHCP_CONF" > "$tmp" && chmod --reference="$DHCP_CONF" "$tmp" && mv "$tmp" "$DHCP_CONF"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Lines of "MAC HOST IP" for every reservation
read_reservations() {
    [[ -s $STATIC_CONF ]] || return 0
    local line re='^host ([^[:space:]]+) \{ hardware ethernet ([^;]+); fixed-address ([^;]+); \}$'
    while IFS= read -r line; do
        if [[ $line =~ $re ]]; then
            echo "${BASH_REMATCH[2]} ${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
        fi
    done < "$STATIC_CONF"
    return 0
}

# Fills LEASE_MAP: MAC -> "IP;HOST", last lease per MAC wins
declare -A LEASE_MAP=()
load_leases() {
    LEASE_MAP=()
    [[ -f $LEASE_FILE ]] || return 0
    local line CUR_IP="" CUR_MAC="" CUR_HOST=""
    while IFS= read -r line; do
        if [[ $line =~ ^lease\ ([0-9.]+) ]]; then
            CUR_IP="${BASH_REMATCH[1]}"; CUR_MAC=""; CUR_HOST=""
        elif [[ $line =~ hardware\ ethernet\ ([a-fA-F0-9:]+) ]]; then
            CUR_MAC="${BASH_REMATCH[1],,}"
        elif [[ $line =~ client-hostname\ \"([^\"]+)\" ]]; then
            CUR_HOST="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^\} ]]; then
            if [[ -n $CUR_MAC && -n $CUR_IP ]]; then
                LEASE_MAP["$CUR_MAC"]="$CUR_IP;${CUR_HOST:-$CUR_MAC}"
            fi
            CUR_IP=""; CUR_MAC=""; CUR_HOST=""
        fi
    done < "$LEASE_FILE"
}

# ---- Static route helpers ----
gateway_for() {
    ip -4 route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'
}

# Stores "DEST IFACE" once per pair; the gateway is looked up at apply time
save_route() {
    local tmp
    tmp=$(mktemp)
    awk -v d="$1" -v i="$2" '!($1 == d && $2 == i)' "$STATIC_ROUTES" > "$tmp" 2>/dev/null || true
    echo "$1 $2" >> "$tmp"
    mv "$tmp" "$STATIC_ROUTES"
}

# ---- HTML page frame ----
html_page() {
    local title="$1" body="$2"
    local LAN_IF HOST_IP
    LAN_IF=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    HOST_IP=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$HOST_IP" ]] && HOST_IP=$(hostname -I | awk '{print $1}')
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
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
    <a href="/reservations" $([ "$title" = "Reservations" ] && echo 'class="active"')>⬢ DHCP</a>
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
        local ip gw state badge metric
        ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet/ {print $2}' | head -n1)
        gw=$(gateway_for "$iface")
        state=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
        metric=$(ip route show default dev "$iface" 2>/dev/null | awk '/metric/ {for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}' | head -n1)
        grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null \
            && badge='<span class="badge badge-red">SUPPRESSED</span>' \
            || { [[ "$state" == "up" ]] && badge='<span class="badge badge-green">UP</span>' || badge='<span class="badge badge-red">DOWN</span>'; }
        wan_block+="<div class='iface-block'><div class='iface-name'>$(html_escape "$iface") $badge</div><div class='iface-detail'>IP: <span class='mono'>${ip:-–}</span><br>GW: <span class='mono'>${gw:-–}</span><br>Metric: <span class='mono'>${metric:-–}</span><br>State: <span class='mono'>$state</span></div></div>"
    done
    local svc_status svc_badge
    svc_status=$(systemctl is-active wan-failover 2>/dev/null)
    [[ "$svc_status" == "active" ]] && svc_badge='<span class="badge badge-green">active</span>' || svc_badge='<span class="badge badge-red">'"$svc_status"'</span>'

    local routing_table state_content failover_log
    routing_table=$(html_escape "$(ip route 2>/dev/null)")
    state_content=$(cat "$STATE_FILE" 2>/dev/null || echo "(empty)")
    failover_log=$(tail -n60 "$FAILOVER_LOG" 2>/dev/null | tac)
    [[ -z $failover_log ]] && failover_log="(no log)"

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
<div class='card'><h2>Routing Table</h2><pre>$routing_table</pre></div>
<div class='card'><h2>Failover State</h2><pre>$(html_escape "$state_content")</pre></div>
</div>
<div class='card'><h2>Failover Log (last 60 lines)</h2><pre class='logbox'>$(html_escape "$failover_log")</pre></div>"
    html_page "WAN Status" "$body"
}

# ---- Routes page ----
page_routes() {
    local msg="$1" body wan_list=""
    [[ -f "$PRIORITY_FILE" ]] && wan_list=$(tail -n1 "$PRIORITY_FILE")
    local select_opts=""
    for i in $wan_list; do select_opts+="<option value='$(html_escape "$i")'>$(html_escape "$i")</option>"; done
    body="<h1>Static Routes</h1>${msg}
<div class='card'><h2>Add route</h2>
<form method='POST' action='/routes/add'><div class='form-row'>
<div class='form-group'><label>Destination</label><input type='text' name='dest' placeholder='172.16.1.1 or 10.5.0.0/24'></div>
<div class='form-group'><label>Interface</label><select name='iface'>$select_opts</select></div>
<button class='btn btn-primary' type='submit'>+ Add</button>
</div></form>
<p style='color:var(--muted);margin-top:12px'>The gateway is detected automatically from the interface's default route.</p></div>
<div class='card'><h2>Saved routes</h2>"
    if [[ -s $STATIC_ROUTES ]]; then
        body+="<table><tr><th>#</th><th>Destination</th><th>Interface</th><th>Gateway</th><th>Kernel</th><th></th></tr>"
        local ln=0 line dest iface gw kb
        while IFS= read -r line; do
            ln=$((ln + 1))
            [[ -z $line ]] && continue
            read -r dest iface _ <<< "$line"
            gw=$(gateway_for "$iface")
            if [[ -n $(ip route show "$dest" dev "$iface" 2>/dev/null) ]]; then
                kb='<span class="badge badge-green">active</span>'
            else
                kb='<span class="badge badge-yellow">missing</span>'
            fi
            body+="<tr><td>$ln</td><td class='mono'>$(html_escape "$dest")</td><td class='mono'>$(html_escape "$iface")</td><td class='mono'>${gw:--}</td><td>$kb</td><td style='display:flex;gap:6px'>
<form method='POST' action='/routes/delete'><input type='hidden' name='line' value='$ln'><button class='btn btn-danger' type='submit'>✕</button></form>
<form method='POST' action='/routes/apply'><input type='hidden' name='line' value='$ln'><button class='btn btn-primary' type='submit'>↺</button></form>
</td></tr>"
        done < "$STATIC_ROUTES"
        body+="</table>"
    else
        body+="<p style='color:var(--muted)'>No saved routes.</p>"
    fi
    body+="</div><div class='card'><h2>Kernel routes</h2><pre>$(html_escape "$(ip route 2>/dev/null)")</pre></div>"
    html_page "Static Routes" "$body"
}

# ---- Reservations page ----
page_reservations() {
    local msg="$1" body mac host ip
    body="<h1>DHCP Reservations</h1>${msg}
<div class='card'><h2>Existing reservations</h2>"
    if [[ -s $STATIC_CONF ]] && [[ -n $(read_reservations) ]]; then
        body+="<table><tr><th>Hostname</th><th>MAC</th><th>IP</th><th></th></tr>"
        while read -r mac host ip; do
            body+="<tr><td class='mono'>$(html_escape "$host")</td><td class='mono'>$mac</td><td class='mono'>$ip</td>
<td><form method='POST' action='/reservations/delete'><input type='hidden' name='mac' value='$mac'><button class='btn btn-danger' type='submit'>✕</button></form></td></tr>"
        done < <(read_reservations)
        body+="</table>"
    else
        body+="<p style='color:var(--muted)'>No reservations.</p>"
    fi

    body+="</div><div class='card'><h2>Active leases</h2>"
    if [[ ! -f $LEASE_FILE ]]; then
        body+="<p style='color:var(--muted)'>Lease file not found.</p>"
    else
        load_leases
        local rows="" count=0 host_name
        local -a macs
        mapfile -t macs < <(printf '%s\n' "${!LEASE_MAP[@]}" | sort)
        for mac in "${macs[@]}"; do
            [[ -z $mac ]] && continue
            grep -qiF "hardware ethernet $mac;" "$STATIC_CONF" 2>/dev/null && continue
            IFS=';' read -r ip host_name <<< "${LEASE_MAP[$mac]}"
            # Hostname from the client is untrusted: keep only valid characters
            host_name="${host_name//[^a-zA-Z0-9-]/}"
            [[ -z $host_name ]] && host_name="host-${mac//:/}"
            count=$((count + 1))
            rows+="<tr><td class='mono'>$ip</td><td class='mono'>$mac</td><td class='mono'>$(html_escape "$host_name")</td>
<td><form method='POST' action='/reservations/add'><input type='hidden' name='ip' value='$ip'><input type='hidden' name='mac' value='$mac'><input type='hidden' name='host' value='$host_name'><button class='btn btn-success' type='submit'>+ Reserve</button></form></td></tr>"
        done
        if (( count > 0 )); then
            body+="<table><tr><th>IP</th><th>MAC</th><th>Hostname</th><th></th></tr>${rows}</table>"
        else
            body+="<p style='color:var(--muted)'>No unreserved leases.</p>"
        fi
    fi

    body+="</div><div class='card'><h2>Add manually</h2>
<form method='POST' action='/reservations/add'><div class='form-row'>
<div class='form-group'><label>MAC</label><input type='text' name='mac' placeholder='aa:bb:cc:dd:ee:ff'></div>
<div class='form-group'><label>IP</label><input type='text' name='ip' placeholder='10.2.0.100'></div>
<div class='form-group'><label>Hostname</label><input type='text' name='host' placeholder='my-device'></div>
<button class='btn btn-primary' type='submit'>+ Add</button>
</div></form></div>"
    html_page "Reservations" "$body"
}

# ---- DNS page ----
page_dns() {
    local msg="$1"
    local cur_dns cur_domain
    cur_dns=$(sed -nE 's/^[[:space:]]*option domain-name-servers ([^;]*);.*/\1/p' "$DHCP_CONF" 2>/dev/null | head -n1)
    cur_domain=$(sed -nE 's/^[[:space:]]*option domain-name "([^"]*)";.*/\1/p' "$DHCP_CONF" 2>/dev/null | head -n1)
    local current
    current=$(grep -E 'domain-name|domain-name-servers' "$DHCP_CONF" 2>/dev/null | head -10)
    local body="<h1>DNS Settings</h1>${msg}
<div class='grid2'>
<div class='card'><h2>DNS Servers</h2>
<form method='POST' action='/dns/save'><div class='form-group' style='margin-bottom:12px'><label>DNS Servers (comma separated)</label>
<input type='text' name='dns' value='$(html_escape "$cur_dns")' style='width:100%'></div>
<button class='btn btn-primary' type='submit'>Save</button></form></div>
<div class='card'><h2>DNS Domain</h2>
<form method='POST' action='/dns/domain'><div class='form-group' style='margin-bottom:12px'><label>Domain</label>
<input type='text' name='domain' value='$(html_escape "$cur_domain")' style='width:100%'></div>
<button class='btn btn-primary' type='submit'>Save</button></form></div>
</div>
<div class='card'><h2>Current configuration</h2><pre>$(html_escape "$current")</pre></div>"
    html_page "DNS" "$body"
}

# ---- HTTP helpers ----
http_200()      { printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"; echo "$1"; }
http_redirect() { printf "HTTP/1.1 302 Found\r\nLocation: %s\r\nConnection: close\r\n\r\n" "$1"; }
alert_ok()      { echo "<div class='alert alert-ok'>✓ $(html_escape "$1")</div>"; }
alert_err()     { echo "<div class='alert alert-err'>✗ $(html_escape "$1")</div>"; }

# ---- Request handler ----
handle_request() {
    ac_check || return 0

    local method path line content_length=0 body_raw=""
    read -r method path _
    method="${method%$'\r'}"; path="${path%$'\r'}"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z $line ]] && break
        if [[ ${line,,} =~ ^content-length:[[:space:]]*([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done
    if [[ $method == "POST" ]] && (( content_length > 0 )); then
        if (( content_length > 65536 )); then
            printf "HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\n\r\n"
            return
        fi
        body_raw=$(dd bs=1 count="$content_length" 2>/dev/null)
    fi
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
        esac
        http_redirect "/" ;;

    "GET /routes")       http_200 "$(page_routes)" ;;
    "POST /routes/add")
        local dest iface gw
        dest=$(get_post_value "$body_raw" "dest" | tr -d ' ')
        iface=$(get_post_value "$body_raw" "iface")
        if ! valid_dest "$dest" || ! valid_iface "$iface"; then
            http_200 "$(page_routes "$(alert_err "Invalid destination or interface")")"; return
        fi
        gw=$(gateway_for "$iface")
        if [[ -z $gw ]]; then
            http_200 "$(page_routes "$(alert_err "No default gateway found on $iface")")"; return
        fi
        if ip route replace "$dest" via "$gw" dev "$iface" 2>/dev/null; then
            save_route "$dest" "$iface"
            http_200 "$(page_routes "$(alert_ok "Route $dest via $iface ($gw) added")")"
        else
            http_200 "$(page_routes "$(alert_err "Failed to apply route $dest via $iface")")"
        fi ;;
    "POST /routes/delete")
        local ln dl dest iface
        ln=$(get_post_value "$body_raw" "line")
        if [[ $ln =~ ^[1-9][0-9]*$ ]] && dl=$(sed -n "${ln}p" "$STATIC_ROUTES" 2>/dev/null) && [[ -n $dl ]]; then
            read -r dest iface _ <<< "$dl"
            ip route del "$dest" dev "$iface" 2>/dev/null || true
            sed -i "${ln}d" "$STATIC_ROUTES"
            http_200 "$(page_routes "$(alert_ok "Route deleted")")"
        else
            http_200 "$(page_routes "$(alert_err "Invalid line")")"
        fi ;;
    "POST /routes/apply")
        local ln al dest iface gw
        ln=$(get_post_value "$body_raw" "line")
        if [[ $ln =~ ^[1-9][0-9]*$ ]] && al=$(sed -n "${ln}p" "$STATIC_ROUTES" 2>/dev/null) && [[ -n $al ]]; then
            read -r dest iface _ <<< "$al"
            gw=$(gateway_for "$iface")
            if [[ -n $gw ]] && ip route replace "$dest" via "$gw" dev "$iface" 2>/dev/null; then
                http_200 "$(page_routes "$(alert_ok "Route $dest applied")")"
            else
                http_200 "$(page_routes "$(alert_err "Could not apply $dest (no gateway on $iface?)")")"
            fi
        else
            http_redirect "/routes"
        fi ;;

    "GET /reservations") http_200 "$(page_reservations)" ;;
    "POST /reservations/add")
        local mac ip host
        mac=$(get_post_value "$body_raw" "mac" | tr 'A-F' 'a-f')
        ip=$(get_post_value "$body_raw" "ip" | tr -d ' ')
        host=$(sanitize_hostname "$(get_post_value "$body_raw" "host")")
        if ! valid_mac "$mac" || ! valid_ipv4 "$ip" || ! valid_hostname "$host"; then
            http_200 "$(page_reservations "$(alert_err "Invalid MAC, IP or hostname")")"; return
        fi
        if grep -qiF "hardware ethernet $mac;" "$STATIC_CONF" 2>/dev/null; then
            http_200 "$(page_reservations "$(alert_err "MAC already reserved")")"; return
        fi
        if grep -qF "fixed-address $ip;" "$STATIC_CONF" 2>/dev/null; then
            http_200 "$(page_reservations "$(alert_err "IP $ip already reserved")")"; return
        fi
        if grep -qE "^host $host \{" "$STATIC_CONF" 2>/dev/null; then
            http_200 "$(page_reservations "$(alert_err "Hostname $host already exists")")"; return
        fi
        make_backup
        touch "$STATIC_CONF"
        echo "host $host { hardware ethernet $mac; fixed-address $ip; }" >> "$STATIC_CONF"
        if apply_dhcp; then
            http_200 "$(page_reservations "$(alert_ok "Reservation for $host ($ip) saved")")"
        else
            http_200 "$(page_reservations "$(alert_err "Change rolled back, DHCP configuration was not applied")")"
        fi ;;
    "POST /reservations/delete")
        local mac; mac=$(get_post_value "$body_raw" "mac" | tr 'A-F' 'a-f')
        if ! valid_mac "$mac" || [[ ! -f $STATIC_CONF ]]; then
            http_redirect "/reservations"; return
        fi
        make_backup
        sed -i "/hardware ethernet ${mac};/d" "$STATIC_CONF"
        if apply_dhcp; then
            http_200 "$(page_reservations "$(alert_ok "Reservation deleted")")"
        else
            http_200 "$(page_reservations "$(alert_err "Change rolled back, DHCP configuration was not applied")")"
        fi ;;

    "GET /dns")          http_200 "$(page_dns)" ;;
    "POST /dns/save")
        local dns; dns=$(get_post_value "$body_raw" "dns" | tr -d ' ')
        if ! valid_dns_list "$dns"; then
            http_200 "$(page_dns "$(alert_err "Invalid DNS server list (comma separated IPv4 addresses)")")"; return
        fi
        dns=${dns//,/, }
        make_backup
        if write_dhcp_conf "s|^([[:space:]]*option domain-name-servers ).*;|\1${dns};|" && apply_dhcp; then
            http_200 "$(page_dns "$(alert_ok "DNS set to $dns")")"
        else
            http_200 "$(page_dns "$(alert_err "Change not applied, previous configuration restored")")"
        fi ;;
    "POST /dns/domain")
        local domain; domain=$(get_post_value "$body_raw" "domain" | tr -d ' ')
        if ! valid_domain "$domain"; then
            http_200 "$(page_dns "$(alert_err "Invalid domain name")")"; return
        fi
        local dom_expr
        if grep -qE '^[[:space:]]*option domain-name "' "$DHCP_CONF" 2>/dev/null; then
            dom_expr="s|^([[:space:]]*option domain-name )\"[^\"]*\";|\1\"${domain}\";|"
        else
            dom_expr="/^[[:space:]]*option domain-name-servers /a\\    option domain-name \"${domain}\";"
        fi
        make_backup
        if write_dhcp_conf "$dom_expr" && apply_dhcp; then
            http_200 "$(page_dns "$(alert_ok "Domain set to $domain")")"
        else
            http_200 "$(page_dns "$(alert_err "Change not applied, previous configuration restored")")"
        fi ;;

    *) printf "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n404" ;;
    esac
}

main() {
    # Child process started by socat for each connection
    if [[ ${1:-} == "--handle" ]]; then
        handle_request
        exit 0
    fi

    local PORT="${1:-8081}"
    local self lan_if ip_addr
    self=$(readlink -f "$0")
    lan_if=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    ip_addr=$(ip -4 addr show dev "$lan_if" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)

    if command -v socat &>/dev/null; then
        log "Starting DHCP WebUI on port $PORT (access control active)"
        log "Open: http://${ip_addr:-<host>}:$PORT"
        exec socat "TCP-LISTEN:$PORT,reuseaddr,fork" "EXEC:/bin/bash $self --handle"
    fi

    # Fallback without socat: no peer address, so access control is not enforced
    log "[WARN] socat not installed, access control is NOT enforced"
    log "Starting DHCP WebUI on port $PORT (nc fallback)"
    log "Open: http://${ip_addr:-<host>}:$PORT"

    local fifo
    fifo=$(mktemp -u)
    mkfifo "$fifo"
    trap "rm -f '$fifo'" EXIT
    while true; do
        handle_request < "$fifo" | nc -q 1 -l -p "$PORT" > "$fifo" 2>/dev/null \
            || handle_request < "$fifo" | nc -l -p "$PORT" > "$fifo" 2>/dev/null \
            || handle_request < "$fifo" | nc -l "$PORT" > "$fifo" 2>/dev/null
    done
}

main "$@"
