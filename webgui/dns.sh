#!/bin/bash
# /etc/1002xOPERATOR/webgui/dns.sh
# 1002xOPERATOR DNS Web Interface
# Port 8084 – display only, logic lives in dns/ shell scripts

PORT="${1:-8084}"
DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_D="/etc/dnsmasq.d"
LOCAL_HOSTS="$DNSMASQ_D/1002x-local-hosts.conf"
CUSTOM_ZONES="$DNSMASQ_D/1002x-custom-zones.conf"
ADBLOCK_CONF="$DNSMASQ_D/1002x-adblock.conf"
ADBLOCK_DIR="/etc/1002xOPERATOR/dns/blocklists"
WHITELIST_FILE="/etc/1002xOPERATOR/dns/whitelist.txt"

log() { echo "[dns-webui] $1"; }

# ── Helpers ──────────────────────────────────────────────────────────────────
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

get_post_value() {
    local body="$1" key="$2"
    local val
    val=$(echo "$body" | tr '&' '\n' | grep "^${key}=" | head -n1 | cut -d'=' -f2-)
    urldecode "$val"
}

get_lan_ip() {
    local lan_if
    lan_if=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    local ip
    ip=$(ip -4 addr show dev "$lan_if" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

reload_dns() {
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null
}

# ── Adblock rebuild – called from request handler ────────────────────────────
rebuild_adblock() {
    local tmpconf
    tmpconf=$(mktemp)
    {
        echo "# 1002xOPERATOR DNS Adblock"
        echo "# Rebuilt: $(date)"
        echo ""
    } > "$tmpconf"

    local wl_pattern=""
    if [[ -s "$WHITELIST_FILE" ]]; then
        wl_pattern=$(grep -v '^#\|^$' "$WHITELIST_FILE" | sed 's/[.*[\^$]/\\&/g' | paste -sd'|' -)
    fi

    for f in "$ADBLOCK_DIR"/*.txt; do
        [[ -f "$f" ]] || continue
        grep -v '^#\|^!\|^$' "$f" | \
        awk '{
            if ($1=="0.0.0.0"||$1=="127.0.0.1"){if($2!="")print $2}
            else if(NF==1&&$0~/^[a-zA-Z0-9._-]+$/)print $0
        }' | \
        grep -v '^localhost$\|^0\.0\.0\.0$\|^127\.' | \
        { [[ -n "$wl_pattern" ]] && grep -Ev "^($wl_pattern)$" || cat; } | \
        sort -u | \
        while IFS= read -r d; do echo "address=/$d/0.0.0.0"; done >> "$tmpconf"
    done

    mv "$tmpconf" "$ADBLOCK_CONF"
    reload_dns
    grep -c '^address=' "$ADBLOCK_CONF" 2>/dev/null || echo 0
}

download_blocklist() {
    local url="$1" name="$2"
    local tmpfile
    tmpfile=$(mktemp)
    if curl -fsSL --max-time 120 "$url" -o "$tmpfile" 2>/dev/null \
    || wget -qO "$tmpfile" --timeout=120 "$url" 2>/dev/null; then
        mv "$tmpfile" "$ADBLOCK_DIR/${name}.txt"
        return 0
    fi
    rm -f "$tmpfile"
    return 1
}

update_all_lists() {
    local stevenblack_url="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    local someonewhocares_url="https://someonewhocares.org/hosts/hosts"
    local adaway_url="https://adaway.org/hosts.txt"
    local oisd_small_url="https://small.oisd.nl/domainswild"
    local hagezi_light_url="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt"
    local updated=0

    [[ -f "$ADBLOCK_DIR/stevenblack.txt" ]]     && download_blocklist "$stevenblack_url"     "stevenblack"     && updated=$((updated+1))
    [[ -f "$ADBLOCK_DIR/someonewhocares.txt" ]]  && download_blocklist "$someonewhocares_url" "someonewhocares" && updated=$((updated+1))
    [[ -f "$ADBLOCK_DIR/adaway.txt" ]]           && download_blocklist "$adaway_url"          "adaway"          && updated=$((updated+1))
    [[ -f "$ADBLOCK_DIR/oisd-small.txt" ]]       && download_blocklist "$oisd_small_url"      "oisd-small"      && updated=$((updated+1))
    [[ -f "$ADBLOCK_DIR/hagezi-light.txt" ]]     && download_blocklist "$hagezi_light_url"    "hagezi-light"    && updated=$((updated+1))

    echo "$updated"
}

# ── Shared layout ─────────────────────────────────────────────────────────────
html_page() {
    local title="$1" body="$2"
    local HOST_IP
    HOST_IP=$(get_lan_ip)
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title – 1002xOPERATOR</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Syne:wght@400;700;800&display=swap');
  :root{--bg:#0a0c10;--surface:#111318;--border:#1e2230;--accent:#00e5ff;--accent2:#ff6b35;--green:#00ff88;--red:#ff3860;--yellow:#ffd600;--purple:#a78bfa;--text:#e2e8f0;--muted:#64748b;--radius:6px}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:13px;min-height:100vh}
  body::before{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,229,255,0.015) 2px,rgba(0,229,255,0.015) 4px);pointer-events:none;z-index:9999}
  header{display:flex;align-items:center;gap:16px;padding:16px 24px;background:var(--surface);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:100;flex-wrap:wrap}
  header .logo{font-family:'Syne',sans-serif;font-weight:800;font-size:18px;color:var(--accent);letter-spacing:-0.5px;text-decoration:none}
  header .logo span{color:var(--accent2)}
  nav{display:flex;gap:4px;margin-left:auto;flex-wrap:wrap}
  nav a{padding:6px 14px;color:var(--muted);text-decoration:none;border-radius:var(--radius);font-size:12px;transition:all 0.15s;border:1px solid transparent}
  nav a:hover,nav a.active{color:var(--purple);border-color:var(--purple);background:rgba(167,139,250,0.05)}
  nav a.home-link{color:var(--accent2);border-color:var(--accent2);background:rgba(255,107,53,0.05)}
  nav a.home-link:hover{background:rgba(255,107,53,0.12)}
  main{max-width:1100px;margin:0 auto;padding:32px 24px}
  h1{font-family:'Syne',sans-serif;font-size:22px;font-weight:800;color:var(--purple);margin-bottom:24px;display:flex;align-items:center;gap:10px}
  h1::before{content:'//';color:var(--accent2);font-family:'JetBrains Mono',monospace}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:20px;margin-bottom:20px}
  .card h2{font-family:'Syne',sans-serif;font-size:14px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid var(--border)}
  table{width:100%;border-collapse:collapse}
  th{text-align:left;padding:8px 12px;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:1px;border-bottom:1px solid var(--border)}
  td{padding:10px 12px;border-bottom:1px solid rgba(30,34,48,0.5);vertical-align:middle}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:rgba(255,255,255,0.02)}
  .badge{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:600}
  .badge-green{background:rgba(0,255,136,0.15);color:var(--green)}
  .badge-red{background:rgba(255,56,96,0.15);color:var(--red)}
  .badge-yellow{background:rgba(255,214,0,0.15);color:var(--yellow)}
  .badge-purple{background:rgba(167,139,250,0.15);color:var(--purple)}
  .badge-blue{background:rgba(0,229,255,0.15);color:var(--accent)}
  .form-row{display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap;margin-top:16px}
  .form-group{display:flex;flex-direction:column;gap:4px}
  .form-group label{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:0.5px}
  input[type=text],select,textarea{background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);color:var(--text);padding:8px 12px;font-family:'JetBrains Mono',monospace;font-size:13px;outline:none;transition:border-color 0.15s;min-width:160px}
  input:focus,select:focus,textarea:focus{border-color:var(--purple)}
  textarea{resize:vertical;min-height:80px;width:100%}
  button,.btn{padding:8px 18px;border-radius:var(--radius);font-family:'JetBrains Mono',monospace;font-size:12px;font-weight:600;cursor:pointer;border:1px solid;transition:all 0.15s;text-decoration:none;display:inline-block}
  .btn-primary{background:rgba(167,139,250,0.1);border-color:var(--purple);color:var(--purple)}
  .btn-primary:hover{background:rgba(167,139,250,0.2)}
  .btn-danger{background:rgba(255,56,96,0.1);border-color:var(--red);color:var(--red)}
  .btn-danger:hover{background:rgba(255,56,96,0.2)}
  .btn-success{background:rgba(0,255,136,0.1);border-color:var(--green);color:var(--green)}
  .btn-success:hover{background:rgba(0,255,136,0.2)}
  .btn-warn{background:rgba(255,214,0,0.1);border-color:var(--yellow);color:var(--yellow)}
  .btn-warn:hover{background:rgba(255,214,0,0.2)}
  pre,.logbox{background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);padding:16px;overflow-x:auto;overflow-y:auto;max-height:380px;font-size:12px;line-height:1.6;color:#94a3b8;white-space:pre-wrap;word-break:break-all}
  .alert{padding:12px 16px;border-radius:var(--radius);margin-bottom:16px;font-size:12px}
  .alert-ok{background:rgba(0,255,136,0.1);border:1px solid var(--green);color:var(--green)}
  .alert-err{background:rgba(255,56,96,0.1);border:1px solid var(--red);color:var(--red)}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
  .grid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:20px}
  .stat-box{background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);padding:16px;text-align:center}
  .stat-val{font-family:'Syne',sans-serif;font-size:28px;font-weight:800;color:var(--purple)}
  .stat-label{font-size:11px;color:var(--muted);margin-top:4px;text-transform:uppercase;letter-spacing:1px}
  .chip{display:inline-flex;align-items:center;gap:6px;background:rgba(167,139,250,0.1);border:1px solid rgba(167,139,250,0.3);border-radius:20px;padding:4px 12px;font-size:12px;color:var(--purple);margin:3px}
  .ifrm{display:inline}
  .mono{font-family:'JetBrains Mono',monospace}
  .muted{color:var(--muted)}
  @media(max-width:700px){.grid2,.grid3{grid-template-columns:1fr}}
</style>
</head>
<body>
<header>
  <a class="logo" href="/">1002x<span>OPERATOR</span></a>
  <nav>
    <a href="http://$HOST_IP:8080" class="home-link">⌂ Portal</a>
    <a href="/" $([ "$title" = "DNS Status" ] && echo 'class="active"')>◈ Status</a>
    <a href="/upstream" $([ "$title" = "Upstream" ] && echo 'class="active"')>⇡ Upstream</a>
    <a href="/hosts" $([ "$title" = "Hosts" ] && echo 'class="active"')>⬢ Hosts</a>
    <a href="/zones" $([ "$title" = "Zones" ] && echo 'class="active"')>⬡ Zones</a>
    <a href="/adblock" $([ "$title" = "Adblock" ] && echo 'class="active"')>✕ Adblock</a>
  </nav>
</header>
<main>
$body
</main>
</body>
</html>
HTML
}

http_200()      { printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"; echo "$1"; }
http_redirect() { printf "HTTP/1.1 302 Found\r\nLocation: $1\r\nConnection: close\r\n\r\n"; }
alert_ok()      { echo "<div class='alert alert-ok'>✓ $1</div>"; }
alert_err()     { echo "<div class='alert alert-err'>✗ $1</div>"; }

# ── Pages ─────────────────────────────────────────────────────────────────────
page_status() {
    local msg="$1"
    local svc svc_color
    svc=$(systemctl is-active dnsmasq 2>/dev/null || echo "unknown")
    [[ "$svc" == "active" ]] && svc_color="var(--green)" || svc_color="var(--red)"

    local host_count zone_count blocked_count
    host_count=$(grep -vc '^#\|^$' "$LOCAL_HOSTS" 2>/dev/null || echo 0)
    zone_count=$(grep -vc '^#\|^$' "$CUSTOM_ZONES" 2>/dev/null || echo 0)
    blocked_count=$(grep -c '^address=' "$ADBLOCK_CONF" 2>/dev/null || echo 0)

    local upstream_chips=""
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        upstream_chips+="<span class='chip'>◈ $s</span>"
    done < <(grep -E '^server=[0-9]' "$DNSMASQ_CONF" 2>/dev/null | sed 's/^server=//')
    [[ -z "$upstream_chips" ]] && upstream_chips="<span class='muted'>No upstream servers configured</span>"

    local domain version lan_if lan_ip
    domain=$(grep '^domain=' "$DNSMASQ_CONF" 2>/dev/null | cut -d= -f2)
    version=$(dnsmasq --version 2>/dev/null | head -1 | awk '{print $3}')
    lan_if=$(grep '^interface=' "$DNSMASQ_CONF" 2>/dev/null | head -1 | cut -d= -f2)
    lan_ip=$(ip -4 addr show dev "$lan_if" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$lan_ip" ]] && lan_ip=$(get_lan_ip)

    local adblock_badge
    [[ "$blocked_count" -gt 0 ]] \
        && adblock_badge="<span class='badge badge-green'>$blocked_count domains</span>" \
        || adblock_badge="<span class='badge badge-yellow'>disabled</span>"

    html_page "DNS Status" "${msg}
<div class='grid3' style='margin-bottom:20px'>
  <div class='stat-box'><div class='stat-val' style='color:$svc_color'>$(echo "$svc" | tr '[:lower:]' '[:upper:]')</div><div class='stat-label'>dnsmasq</div></div>
  <div class='stat-box'><div class='stat-val'>$host_count</div><div class='stat-label'>Local Hosts</div></div>
  <div class='stat-box'><div class='stat-val'>$blocked_count</div><div class='stat-label'>Blocked Domains</div></div>
</div>
<div class='card'><h2>Service Control</h2>
<div style='display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px'>
  <form class='ifrm' method='POST' action='/service'><input type='hidden' name='action' value='start'><button class='btn btn-success'>▶ Start</button></form>
  <form class='ifrm' method='POST' action='/service'><input type='hidden' name='action' value='stop'><button class='btn btn-danger'>■ Stop</button></form>
  <form class='ifrm' method='POST' action='/service'><input type='hidden' name='action' value='restart'><button class='btn btn-primary'>↺ Restart</button></form>
  <form class='ifrm' method='POST' action='/service'><input type='hidden' name='action' value='reload'><button class='btn btn-warn'>⟳ Reload</button></form>
</div>
<table>
  <tr><th>Property</th><th>Value</th></tr>
  <tr><td class='muted'>Version</td><td class='mono'>${version:-unknown}</td></tr>
  <tr><td class='muted'>Interface</td><td class='mono'>${lan_if:--}  ($lan_ip)</td></tr>
  <tr><td class='muted'>Domain</td><td class='mono'>${domain:-(none)}</td></tr>
  <tr><td class='muted'>Adblock</td><td>$adblock_badge</td></tr>
  <tr><td class='muted'>Config</td><td class='mono'>$DNSMASQ_CONF</td></tr>
</table></div>
<div class='card'><h2>Upstream DNS</h2>
<div style='margin-bottom:12px'>$upstream_chips</div>
<a href='/upstream' class='btn btn-primary' style='font-size:11px'>Manage upstream →</a>
</div>
<div class='grid2'>
  <div class='card'><h2>systemctl status</h2><pre>$(systemctl status dnsmasq 2>/dev/null | head -20 || echo "(not available)")</pre></div>
  <div class='card'><h2>Live Log</h2><pre class='logbox'>$(journalctl -u dnsmasq -n 50 --no-pager 2>/dev/null | tac || echo "(no log)")</pre></div>
</div>"
}

page_upstream() {
    local msg="$1"
    local rows="" idx=1
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        local name
        case "$s" in
            1.1.1.1)         name="Cloudflare Primary" ;;
            1.0.0.1)         name="Cloudflare Secondary" ;;
            8.8.8.8)         name="Google Primary" ;;
            8.8.4.4)         name="Google Secondary" ;;
            9.9.9.9)         name="Quad9 Primary" ;;
            149.112.112.112) name="Quad9 Secondary" ;;
            208.67.222.222)  name="OpenDNS Primary" ;;
            208.67.220.220)  name="OpenDNS Secondary" ;;
            127.0.0.1)       name="Localhost" ;;
            *)               name="Custom" ;;
        esac
        rows+="<tr><td>$idx</td><td class='mono'>$s</td><td class='muted'>$name</td>
          <td><form class='ifrm' method='POST' action='/upstream/delete'>
            <input type='hidden' name='server' value='$s'>
            <button class='btn btn-danger' style='padding:4px 10px;font-size:11px'>✕</button>
          </form></td></tr>"
        idx=$((idx+1))
    done < <(grep -E '^server=[0-9]' "$DNSMASQ_CONF" 2>/dev/null | sed 's/^server=//')

    local table
    [[ -n "$rows" ]] \
        && table="<table><tr><th>#</th><th>IP</th><th>Provider</th><th></th></tr>$rows</table>" \
        || table="<p class='muted'>No upstream servers configured.</p>"

    html_page "Upstream" "${msg}
<div class='card'><h2>Add Server</h2>
<form method='POST' action='/upstream/add'>
  <div class='form-row'>
    <div class='form-group'><label>IP Address</label><input type='text' name='server' placeholder='e.g. 1.1.1.1' style='min-width:200px'></div>
    <button class='btn btn-primary' type='submit'>+ Add</button>
  </div>
</form>
<div style='margin-top:14px'>
  <span class='muted' style='font-size:11px;text-transform:uppercase;letter-spacing:1px'>Presets: </span>
  <form class='ifrm' method='POST' action='/upstream/preset'><input type='hidden' name='preset' value='cloudflare'><button class='btn btn-primary' style='margin:3px;font-size:11px'>Cloudflare</button></form>
  <form class='ifrm' method='POST' action='/upstream/preset'><input type='hidden' name='preset' value='google'><button class='btn btn-primary' style='margin:3px;font-size:11px'>Google</button></form>
  <form class='ifrm' method='POST' action='/upstream/preset'><input type='hidden' name='preset' value='quad9'><button class='btn btn-primary' style='margin:3px;font-size:11px'>Quad9</button></form>
  <form class='ifrm' method='POST' action='/upstream/preset'><input type='hidden' name='preset' value='opendns'><button class='btn btn-primary' style='margin:3px;font-size:11px'>OpenDNS</button></form>
</div></div>
<div class='card'><h2>Configured Servers</h2>$table</div>
<div class='card'><h2>server= entries in dnsmasq.conf</h2>
<pre>$(grep '^server=' "$DNSMASQ_CONF" 2>/dev/null || echo "# none")</pre>
</div>"
}

page_hosts() {
    local msg="$1"
    local rows="" idx=1
    if [[ -f "$LOCAL_HOSTS" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            rows+="<tr><td>$idx</td><td class='mono' style='font-size:12px'>$line</td>
              <td><form class='ifrm' method='POST' action='/hosts/delete'>
                <input type='hidden' name='lineno' value='$idx'>
                <button class='btn btn-danger' style='padding:4px 10px;font-size:11px'>✕</button>
              </form></td></tr>"
            idx=$((idx+1))
        done < "$LOCAL_HOSTS"
    fi
    local count=$((idx-1))
    local table
    [[ -n "$rows" ]] \
        && table="<table><tr><th>#</th><th>Directive</th><th></th></tr>$rows</table>" \
        || table="<p class='muted'>No local host entries configured.</p>"

    html_page "Hosts" "${msg}
<div class='grid2'>
<div class='card'><h2>Add Host Entry</h2>
<form method='POST' action='/hosts/add'>
  <div class='form-group' style='margin-bottom:10px'><label>Hostname</label>
  <input type='text' name='hostname' placeholder='printer.home.lan' style='width:100%'></div>
  <div class='form-group' style='margin-bottom:10px'><label>IP Address</label>
  <input type='text' name='ip' placeholder='192.168.1.50' style='width:100%'></div>
  <label style='display:flex;align-items:center;gap:8px;font-size:12px;color:var(--muted);margin-bottom:12px'>
    <input type='checkbox' name='ptr' value='1'> Also add reverse PTR record
  </label>
  <button class='btn btn-primary' type='submit'>+ Add</button>
</form></div>
<div class='card'><h2>Raw File Editor</h2>
<p class='muted' style='font-size:12px;margin-bottom:10px'>$LOCAL_HOSTS</p>
<form method='POST' action='/hosts/rawsave'>
  <textarea name='content' style='min-height:160px'>$(cat "$LOCAL_HOSTS" 2>/dev/null)</textarea>
  <div style='margin-top:10px'><button class='btn btn-primary' type='submit'>💾 Save &amp; Reload</button></div>
</form></div>
</div>
<div class='card'><h2>Host Entries [$count]</h2>$table</div>"
}

page_zones() {
    local msg="$1"
    local rows="" idx=1
    if [[ -f "$CUSTOM_ZONES" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            local badge
            [[ "$line" =~ ^address= ]]      && badge="<span class='badge badge-purple'>address</span>"
            [[ "$line" =~ ^server=.+/.+/ ]] && badge="<span class='badge badge-yellow'>forward</span>"
            [[ "$line" =~ ^local= ]]        && badge="<span class='badge badge-blue'>local</span>"
            [[ -z "$badge" ]]               && badge="<span class='badge badge-purple'>custom</span>"
            rows+="<tr><td>$idx</td><td>$badge</td><td class='mono' style='font-size:12px'>$line</td>
              <td><form class='ifrm' method='POST' action='/zones/delete'>
                <input type='hidden' name='lineno' value='$idx'>
                <button class='btn btn-danger' style='padding:4px 10px;font-size:11px'>✕</button>
              </form></td></tr>"
            idx=$((idx+1))
        done < "$CUSTOM_ZONES"
    fi
    local count=$((idx-1))
    local table
    [[ -n "$rows" ]] \
        && table="<table><tr><th>#</th><th>Type</th><th>Directive</th><th></th></tr>$rows</table>" \
        || table="<p class='muted'>No custom zone entries configured.</p>"

    html_page "Zones" "${msg}
<div class='grid2'>
<div class='card'><h2>address= (Domain → IP)</h2>
<form method='POST' action='/zones/add-address'>
  <div class='form-group' style='margin-bottom:10px'><label>Domain</label>
  <input type='text' name='domain' placeholder='nas.home.lan' style='width:100%'></div>
  <div class='form-group' style='margin-bottom:10px'><label>Target IP</label>
  <input type='text' name='ip' placeholder='192.168.1.100' style='width:100%'></div>
  <button class='btn btn-primary' type='submit'>+ Add</button>
</form></div>
<div class='card'><h2>server= (Forward → Nameserver)</h2>
<form method='POST' action='/zones/add-forward'>
  <div class='form-group' style='margin-bottom:10px'><label>Domain</label>
  <input type='text' name='domain' placeholder='company.internal' style='width:100%'></div>
  <div class='form-group' style='margin-bottom:10px'><label>Nameserver IP</label>
  <input type='text' name='ns' placeholder='10.0.0.1' style='width:100%'></div>
  <button class='btn btn-primary' type='submit'>+ Add</button>
</form></div>
</div>
<div class='card'><h2>local= (No Upstream Forward)</h2>
<form method='POST' action='/zones/add-local'>
  <div class='form-row'>
    <div class='form-group'><label>Domain</label><input type='text' name='domain' placeholder='.lan' style='min-width:200px'></div>
    <button class='btn btn-warn' type='submit'>+ Mark local</button>
  </div>
</form></div>
<div class='card'><h2>Raw File Editor</h2>
<form method='POST' action='/zones/rawsave'>
  <textarea name='content' style='min-height:140px'>$(cat "$CUSTOM_ZONES" 2>/dev/null)</textarea>
  <div style='margin-top:10px'><button class='btn btn-primary' type='submit'>💾 Save &amp; Reload</button></div>
</form></div>
<div class='card'><h2>Zone Entries [$count]</h2>$table</div>"
}

page_adblock() {
    local msg="$1"
    local blocked wl_count bl_count
    blocked=$(grep -c '^address=' "$ADBLOCK_CONF" 2>/dev/null || echo 0)
    wl_count=$(grep -vc '^#\|^$' "$WHITELIST_FILE" 2>/dev/null || echo 0)
    bl_count=$(ls -1 "$ADBLOCK_DIR"/*.txt 2>/dev/null | wc -l)

    local status_badge toggle_btn
    if [[ "$blocked" -gt 0 ]]; then
        status_badge="<span class='badge badge-green'>ENABLED – $blocked domains</span>"
        toggle_btn="<form class='ifrm' method='POST' action='/adblock/toggle'><input type='hidden' name='action' value='disable'><button class='btn btn-danger'>■ Disable</button></form>"
    else
        status_badge="<span class='badge badge-yellow'>DISABLED</span>"
        toggle_btn="<form class='ifrm' method='POST' action='/adblock/toggle'><input type='hidden' name='action' value='enable'><button class='btn btn-success'>▶ Enable</button></form>"
    fi

    local bl_rows=""
    for f in "$ADBLOCK_DIR"/*.txt; do
        [[ -f "$f" ]] || continue
        local fname n
        fname=$(basename "$f")
        n=$(grep -vc '^#\|^!\|^$' "$f" 2>/dev/null || echo 0)
        bl_rows+="<tr><td class='mono' style='font-size:12px'>$fname</td><td><span class='badge badge-purple'>$n</span></td>
          <td><form class='ifrm' method='POST' action='/adblock/remove-list'>
            <input type='hidden' name='file' value='$fname'>
            <button class='btn btn-danger' style='padding:4px 10px;font-size:11px'>✕</button>
          </form></td></tr>"
    done

    local wl_rows="" widx=1
    if [[ -f "$WHITELIST_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            wl_rows+="<tr><td class='mono'>$line</td>
              <td><form class='ifrm' method='POST' action='/adblock/whitelist-delete'>
                <input type='hidden' name='lineno' value='$widx'>
                <button class='btn btn-danger' style='padding:4px 10px;font-size:11px'>✕</button>
              </form></td></tr>"
            widx=$((widx+1))
        done < "$WHITELIST_FILE"
    fi

    local bl_table wl_table
    [[ -n "$bl_rows" ]] \
        && bl_table="<table><tr><th>File</th><th>Entries</th><th></th></tr>$bl_rows</table>" \
        || bl_table="<p class='muted'>No blocklists loaded.</p>"
    [[ -n "$wl_rows" ]] \
        && wl_table="<table><tr><th>Domain</th><th></th></tr>$wl_rows</table>" \
        || wl_table="<p class='muted'>Whitelist is empty.</p>"

    html_page "Adblock" "${msg}
<div class='grid3' style='margin-bottom:20px'>
  <div class='stat-box'><div class='stat-val'>$blocked</div><div class='stat-label'>Blocked Domains</div></div>
  <div class='stat-box'><div class='stat-val'>$bl_count</div><div class='stat-label'>Blocklists</div></div>
  <div class='stat-box'><div class='stat-val'>$wl_count</div><div class='stat-label'>Whitelisted</div></div>
</div>
<div class='card'><h2>Status $status_badge</h2>
<div style='display:flex;gap:10px;flex-wrap:wrap'>
  $toggle_btn
  <form class='ifrm' method='POST' action='/adblock/rebuild'><button class='btn btn-warn'>↺ Rebuild</button></form>
  <form class='ifrm' method='POST' action='/adblock/update'><button class='btn btn-success'>⬇ Update all lists</button></form>
</div></div>
<div class='grid2'>
<div class='card'><h2>Download Preset</h2>
<form method='POST' action='/adblock/preset'>
  <div class='form-group' style='margin-bottom:10px'><label>Preset</label>
  <select name='preset' style='width:100%'>
    <option value='stevenblack'>Steven Black Unified (~130k domains)</option>
    <option value='someonewhocares'>Dan Pollock (~15k domains)</option>
    <option value='adaway'>AdAway (~400 entries)</option>
    <option value='oisd-small'>OISD Small (~50k domains)</option>
    <option value='hagezi-light'>HaGeZi Light (~200k domains)</option>
  </select></div>
  <button class='btn btn-primary' type='submit'>⬇ Download</button>
</form></div>
<div class='card'><h2>Custom URL</h2>
<form method='POST' action='/adblock/download'>
  <div class='form-group' style='margin-bottom:10px'><label>URL</label>
  <input type='text' name='url' placeholder='https://example.com/hosts.txt' style='width:100%'></div>
  <div class='form-group' style='margin-bottom:10px'><label>Name</label>
  <input type='text' name='name' placeholder='mylist' style='width:100%'></div>
  <button class='btn btn-primary' type='submit'>⬇ Download</button>
</form></div>
</div>
<div class='card'><h2>Block Domain Manually</h2>
<form method='POST' action='/adblock/block-domain'>
  <div class='form-row'>
    <div class='form-group'><label>Domain</label><input type='text' name='domain' placeholder='ads.example.com' style='min-width:260px'></div>
    <button class='btn btn-danger' type='submit'>✕ Block</button>
  </div>
</form></div>
<div class='grid2'>
<div class='card'><h2>Loaded Blocklists</h2>$bl_table</div>
<div class='card'><h2>Whitelist [$wl_count]</h2>
<form method='POST' action='/adblock/whitelist-add' style='margin-bottom:12px'>
  <div class='form-row'>
    <div class='form-group'><label>Domain</label><input type='text' name='domain' placeholder='github.com' style='min-width:180px'></div>
    <button class='btn btn-success' type='submit'>✓ Allow</button>
  </div>
</form>
$wl_table</div>
</div>"
}

# ── Request handler ───────────────────────────────────────────────────────────
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

    case "$method $path" in

    "GET /")
        http_200 "$(page_status)" ;;

    "POST /service")
        local action; action=$(get_post_value "$body_raw" "action")
        case "$action" in
            start)   systemctl start   dnsmasq 2>/dev/null ;;
            stop)    systemctl stop    dnsmasq 2>/dev/null ;;
            restart) systemctl restart dnsmasq 2>/dev/null ;;
            reload)  reload_dns ;;
        esac
        http_redirect "/" ;;

    "GET /upstream")
        http_200 "$(page_upstream)" ;;

    "POST /upstream/add")
        local server; server=$(get_post_value "$body_raw" "server")
        server="${server//[^0-9a-f.:]/}"
        if [[ -z "$server" ]]; then
            http_200 "$(page_upstream "$(alert_err "No valid IP provided")")"; return
        fi
        if grep -q "^server=$server$" "$DNSMASQ_CONF" 2>/dev/null; then
            http_200 "$(page_upstream "$(alert_err "$server already configured")")"; return
        fi
        cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak" 2>/dev/null
        echo "server=$server" >> "$DNSMASQ_CONF"
        reload_dns
        http_200 "$(page_upstream "$(alert_ok "Added $server")")" ;;

    "POST /upstream/preset")
        local preset; preset=$(get_post_value "$body_raw" "preset")
        cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak" 2>/dev/null
        sed -i '/^server=[0-9]/d' "$DNSMASQ_CONF"
        case "$preset" in
            cloudflare) printf 'server=1.1.1.1\nserver=1.0.0.1\n' >> "$DNSMASQ_CONF" ;;
            google)     printf 'server=8.8.8.8\nserver=8.8.4.4\n' >> "$DNSMASQ_CONF" ;;
            quad9)      printf 'server=9.9.9.9\nserver=149.112.112.112\n' >> "$DNSMASQ_CONF" ;;
            opendns)    printf 'server=208.67.222.222\nserver=208.67.220.220\n' >> "$DNSMASQ_CONF" ;;
        esac
        reload_dns
        http_200 "$(page_upstream "$(alert_ok "Preset $preset applied")")" ;;

    "POST /upstream/delete")
        local server; server=$(get_post_value "$body_raw" "server")
        server="${server//[^0-9.]/}"
        cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak" 2>/dev/null
        sed -i "/^server=${server//./\\.}$/d" "$DNSMASQ_CONF"
        reload_dns
        http_200 "$(page_upstream "$(alert_ok "Removed $server")")" ;;

    "GET /hosts")
        http_200 "$(page_hosts)" ;;

    "POST /hosts/add")
        local hostname ip ptr
        hostname=$(get_post_value "$body_raw" "hostname")
        ip=$(get_post_value "$body_raw" "ip")
        ptr=$(get_post_value "$body_raw" "ptr")
        hostname="${hostname//[^a-zA-Z0-9._-]/}"
        ip="${ip//[^0-9.]/}"
        if [[ -z "$hostname" || -z "$ip" ]]; then
            http_200 "$(page_hosts "$(alert_err "Hostname and IP required")")"; return
        fi
        cp "$LOCAL_HOSTS" "${LOCAL_HOSTS}.bak" 2>/dev/null
        grep -v "^address=/$hostname/" "$LOCAL_HOSTS" > "${LOCAL_HOSTS}.tmp" 2>/dev/null \
            && mv "${LOCAL_HOSTS}.tmp" "$LOCAL_HOSTS"
        echo "address=/$hostname/$ip" >> "$LOCAL_HOSTS"
        if [[ "$ptr" == "1" ]]; then
            local rev; rev=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
            echo "ptr-record=${rev}.in-addr.arpa,$hostname" >> "$LOCAL_HOSTS"
        fi
        reload_dns
        http_200 "$(page_hosts "$(alert_ok "Added $hostname → $ip${ptr:+ (with PTR)}")")" ;;

    "POST /hosts/delete")
        local lineno; lineno=$(get_post_value "$body_raw" "lineno")
        if [[ "$lineno" =~ ^[0-9]+$ ]]; then
            cp "$LOCAL_HOSTS" "${LOCAL_HOSTS}.bak" 2>/dev/null
            awk -v n="$lineno" '!/^#|^$/{c++;if(c==n)next}1' "$LOCAL_HOSTS" \
                > "${LOCAL_HOSTS}.tmp" && mv "${LOCAL_HOSTS}.tmp" "$LOCAL_HOSTS"
            reload_dns
            http_200 "$(page_hosts "$(alert_ok "Entry $lineno deleted")")"
        else
            http_200 "$(page_hosts "$(alert_err "Invalid line number")")"
        fi ;;

    "POST /hosts/rawsave")
        local content; content=$(get_post_value "$body_raw" "content")
        cp "$LOCAL_HOSTS" "${LOCAL_HOSTS}.bak" 2>/dev/null
        printf '%b' "$content" > "$LOCAL_HOSTS"
        reload_dns
        http_200 "$(page_hosts "$(alert_ok "Saved and reloaded")")" ;;

    "GET /zones")
        http_200 "$(page_zones)" ;;

    "POST /zones/add-address")
        local domain ip
        domain=$(get_post_value "$body_raw" "domain")
        ip=$(get_post_value "$body_raw" "ip")
        domain="${domain//[^a-zA-Z0-9._-]/}"
        ip="${ip//[^0-9.]/}"
        if [[ -z "$domain" || -z "$ip" ]]; then
            http_200 "$(page_zones "$(alert_err "Domain and IP required")")"; return
        fi
        cp "$CUSTOM_ZONES" "${CUSTOM_ZONES}.bak" 2>/dev/null
        echo "address=/$domain/$ip" >> "$CUSTOM_ZONES"
        reload_dns
        http_200 "$(page_zones "$(alert_ok "Added address=/$domain/$ip")")" ;;

    "POST /zones/add-forward")
        local domain ns
        domain=$(get_post_value "$body_raw" "domain")
        ns=$(get_post_value "$body_raw" "ns")
        domain="${domain//[^a-zA-Z0-9._-]/}"
        ns="${ns//[^0-9.]/}"
        if [[ -z "$domain" || -z "$ns" ]]; then
            http_200 "$(page_zones "$(alert_err "Domain and nameserver required")")"; return
        fi
        cp "$CUSTOM_ZONES" "${CUSTOM_ZONES}.bak" 2>/dev/null
        echo "server=/$domain/$ns" >> "$CUSTOM_ZONES"
        reload_dns
        http_200 "$(page_zones "$(alert_ok "Added server=/$domain/$ns")")" ;;

    "POST /zones/add-local")
        local domain; domain=$(get_post_value "$body_raw" "domain")
        domain="${domain//[^a-zA-Z0-9._-]/}"
        if [[ -z "$domain" ]]; then
            http_200 "$(page_zones "$(alert_err "Domain required")")"; return
        fi
        cp "$CUSTOM_ZONES" "${CUSTOM_ZONES}.bak" 2>/dev/null
        echo "local=/$domain/" >> "$CUSTOM_ZONES"
        reload_dns
        http_200 "$(page_zones "$(alert_ok "Added local=/$domain/")")" ;;

    "POST /zones/delete")
        local lineno; lineno=$(get_post_value "$body_raw" "lineno")
        if [[ "$lineno" =~ ^[0-9]+$ ]]; then
            cp "$CUSTOM_ZONES" "${CUSTOM_ZONES}.bak" 2>/dev/null
            awk -v n="$lineno" '!/^#|^$/{c++;if(c==n)next}1' "$CUSTOM_ZONES" \
                > "${CUSTOM_ZONES}.tmp" && mv "${CUSTOM_ZONES}.tmp" "$CUSTOM_ZONES"
            reload_dns
            http_200 "$(page_zones "$(alert_ok "Entry $lineno deleted")")"
        else
            http_200 "$(page_zones "$(alert_err "Invalid line number")")"
        fi ;;

    "POST /zones/rawsave")
        local content; content=$(get_post_value "$body_raw" "content")
        cp "$CUSTOM_ZONES" "${CUSTOM_ZONES}.bak" 2>/dev/null
        printf '%b' "$content" > "$CUSTOM_ZONES"
        reload_dns
        http_200 "$(page_zones "$(alert_ok "Saved and reloaded")")" ;;

    "GET /adblock")
        http_200 "$(page_adblock)" ;;

    "POST /adblock/toggle")
        local action; action=$(get_post_value "$body_raw" "action")
        if [[ "$action" == "disable" ]]; then
            echo "# 1002xOPERATOR DNS Adblock – disabled" > "$ADBLOCK_CONF"
            reload_dns
            http_200 "$(page_adblock "$(alert_ok "Adblocking disabled")")"
        else
            local total; total=$(rebuild_adblock)
            http_200 "$(page_adblock "$(alert_ok "Adblocking enabled – $total domains blocked")")"
        fi ;;

    "POST /adblock/rebuild")
        local total; total=$(rebuild_adblock)
        http_200 "$(page_adblock "$(alert_ok "Rebuilt – $total domains blocked")")" ;;

    "POST /adblock/preset")
        local preset url
        preset=$(get_post_value "$body_raw" "preset")
        case "$preset" in
            stevenblack)     url="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ;;
            someonewhocares) url="https://someonewhocares.org/hosts/hosts" ;;
            adaway)          url="https://adaway.org/hosts.txt" ;;
            oisd-small)      url="https://small.oisd.nl/domainswild" ;;
            hagezi-light)    url="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt" ;;
            *)               http_redirect "/adblock"; return ;;
        esac
        mkdir -p "$ADBLOCK_DIR"
        if download_blocklist "$url" "$preset"; then
            local total; total=$(rebuild_adblock)
            http_200 "$(page_adblock "$(alert_ok "Downloaded $preset – $total domains blocked")")"
        else
            http_200 "$(page_adblock "$(alert_err "Download failed for $preset")")"
        fi ;;

    "POST /adblock/download")
        local url name
        url=$(get_post_value "$body_raw" "url")
        name=$(get_post_value "$body_raw" "name")
        name="${name//[^a-zA-Z0-9_-]/}"
        if [[ -z "$url" || -z "$name" ]]; then
            http_200 "$(page_adblock "$(alert_err "URL and name required")")"; return
        fi
        mkdir -p "$ADBLOCK_DIR"
        if download_blocklist "$url" "$name"; then
            local total; total=$(rebuild_adblock)
            http_200 "$(page_adblock "$(alert_ok "Downloaded $name – $total domains blocked")")"
        else
            http_200 "$(page_adblock "$(alert_err "Download failed: $url")")"
        fi ;;

    "POST /adblock/block-domain")
        local domain; domain=$(get_post_value "$body_raw" "domain")
        domain="${domain//[^a-zA-Z0-9._-]/}"
        if [[ -z "$domain" ]]; then
            http_200 "$(page_adblock "$(alert_err "Invalid domain")")"; return
        fi
        mkdir -p "$ADBLOCK_DIR"
        grep -qx "$domain" "$ADBLOCK_DIR/manual.txt" 2>/dev/null \
            || echo "$domain" >> "$ADBLOCK_DIR/manual.txt"
        local total; total=$(rebuild_adblock)
        http_200 "$(page_adblock "$(alert_ok "$domain blocked – $total total")")" ;;

    "POST /adblock/remove-list")
        local file; file=$(get_post_value "$body_raw" "file")
        file="${file//[^a-zA-Z0-9._-]/}"
        rm -f "$ADBLOCK_DIR/$file"
        local total; total=$(rebuild_adblock)
        http_200 "$(page_adblock "$(alert_ok "$file removed – $total domains blocked")")" ;;

    "POST /adblock/whitelist-add")
        local domain; domain=$(get_post_value "$body_raw" "domain")
        domain="${domain//[^a-zA-Z0-9._-]/}"
        if [[ -z "$domain" ]]; then
            http_200 "$(page_adblock "$(alert_err "Invalid domain")")"; return
        fi
        mkdir -p "$(dirname "$WHITELIST_FILE")"
        touch "$WHITELIST_FILE"
        grep -qx "$domain" "$WHITELIST_FILE" 2>/dev/null \
            || echo "$domain" >> "$WHITELIST_FILE"
        local total; total=$(rebuild_adblock)
        http_200 "$(page_adblock "$(alert_ok "$domain whitelisted – $total blocked")")" ;;

    "POST /adblock/whitelist-delete")
        local lineno; lineno=$(get_post_value "$body_raw" "lineno")
        if [[ "$lineno" =~ ^[0-9]+$ ]]; then
            awk -v n="$lineno" '!/^#|^$/{c++;if(c==n)next}1' "$WHITELIST_FILE" \
                > "${WHITELIST_FILE}.tmp" && mv "${WHITELIST_FILE}.tmp" "$WHITELIST_FILE"
            local total; total=$(rebuild_adblock)
            http_200 "$(page_adblock "$(alert_ok "Whitelist entry removed – $total blocked")")"
        else
            http_200 "$(page_adblock "$(alert_err "Invalid line number")")"
        fi ;;

    "POST /adblock/update")
        local updated; updated=$(update_all_lists)
        local total; total=$(rebuild_adblock)
        http_200 "$(page_adblock "$(alert_ok "Updated $updated list(s) – $total domains blocked")")" ;;

    *)
        printf "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n404" ;;
    esac
}

# ── Server loop ───────────────────────────────────────────────────────────────
# Release port if already in use
fuser -k "${PORT}/tcp" 2>/dev/null || true

log "Starting 1002xOPERATOR DNS WebUI on port $PORT"
log "Open: http://$(get_lan_ip):$PORT"

FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap "rm -f '$FIFO'" EXIT

while true; do
    handle_request < "$FIFO" | nc -q 1 -l -p "$PORT" > "$FIFO" 2>/dev/null || \
    handle_request < "$FIFO" | nc -l -p "$PORT" > "$FIFO" 2>/dev/null || \
    handle_request < "$FIFO" | nc -l "$PORT" > "$FIFO" 2>/dev/null
done
