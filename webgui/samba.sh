#!/bin/bash
# samba.sh – 1002xOPERATOR Samba Web Interface
# Runs as a simple HTTP server using netcat (nc)
# Usage: bash samba-webui.sh [port]   (default port: 8081)

PORT="${1:-8082}"
SMB="/etc/samba/smb.conf"
BASE="/etc/1002xOPERATOR/samba"

log() { echo "[samba-webui] $1"; }

# -------------------------------------------------------------------
# URL decode
# -------------------------------------------------------------------
urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

get_post_value() {
    local body="$1" key="$2"
    local val
    val=$(echo "$body" | tr '&' '\n' | grep "^${key}=" | head -n1 | cut -d'=' -f2-)
    urldecode "$val"
}

# -------------------------------------------------------------------
# HTML shell (shared style)
# -------------------------------------------------------------------
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
  :root {
    --bg: #0a0c10;
    --surface: #111318;
    --border: #1e2230;
    --accent: #00e5ff;
    --accent2: #ff6b35;
    --green: #00ff88;
    --red: #ff3860;
    --yellow: #ffd600;
    --text: #e2e8f0;
    --muted: #64748b;
    --radius: 6px;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'JetBrains Mono', monospace;
    font-size: 13px;
    min-height: 100vh;
  }
  body::before {
    content: '';
    position: fixed; inset: 0;
    background: repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0,229,255,0.015) 2px, rgba(0,229,255,0.015) 4px);
    pointer-events: none; z-index: 9999;
  }
  header {
    display: flex; align-items: center; gap: 16px;
    padding: 16px 24px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    position: sticky; top: 0; z-index: 100;
  }
  header .logo {
    font-family: 'Syne', sans-serif;
    font-weight: 800; font-size: 18px;
    color: var(--accent);
    letter-spacing: -0.5px;
    text-decoration: none;
  }
  header .logo span { color: var(--accent2); }
  header .logo .sub { font-size: 11px; color: var(--muted); margin-left: 8px; font-family: 'JetBrains Mono', monospace; }
  nav { display: flex; gap: 4px; margin-left: auto; }
  nav a {
    padding: 6px 14px;
    color: var(--muted);
    text-decoration: none;
    border-radius: var(--radius);
    font-size: 12px;
    transition: all 0.15s;
    border: 1px solid transparent;
  }
  nav a:hover, nav a.active {
    color: var(--accent);
    border-color: var(--accent);
    background: rgba(0,229,255,0.05);
  }
  nav a.home-link {
    color: var(--accent2);
    border-color: var(--accent2);
    background: rgba(255,107,53,0.05);
  }
  nav a.home-link:hover { background: rgba(255,107,53,0.12); }
  main { max-width: 1100px; margin: 0 auto; padding: 32px 24px; }
  h1 {
    font-family: 'Syne', sans-serif;
    font-size: 22px; font-weight: 800;
    color: var(--accent);
    margin-bottom: 24px;
    display: flex; align-items: center; gap: 10px;
  }
  h1::before { content: '//'; color: var(--accent2); font-family: 'JetBrains Mono', monospace; }
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px;
    margin-bottom: 20px;
  }
  .card h2 {
    font-family: 'Syne', sans-serif;
    font-size: 14px; font-weight: 700;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 1px;
    margin-bottom: 16px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border);
  }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; padding: 8px 12px; color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 1px; border-bottom: 1px solid var(--border); }
  td { padding: 10px 12px; border-bottom: 1px solid rgba(30,34,48,0.5); }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(255,255,255,0.02); }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 11px; font-weight: 600; }
  .badge-green { background: rgba(0,255,136,0.15); color: var(--green); }
  .badge-red   { background: rgba(255,56,96,0.15);  color: var(--red); }
  .badge-blue  { background: rgba(0,229,255,0.15);  color: var(--accent); }
  .form-row { display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap; margin-top: 16px; }
  .form-group { display: flex; flex-direction: column; gap: 4px; }
  .form-group label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
  input[type=text], select {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    color: var(--text);
    padding: 8px 12px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 13px;
    outline: none;
    transition: border-color 0.15s;
    min-width: 200px;
  }
  input:focus { border-color: var(--accent); }
  button, .btn {
    padding: 8px 18px;
    border-radius: var(--radius);
    font-family: 'JetBrains Mono', monospace;
    font-size: 12px; font-weight: 600;
    cursor: pointer; border: 1px solid;
    transition: all 0.15s;
    text-decoration: none;
    display: inline-block;
  }
  .btn-primary { background: rgba(0,229,255,0.1); border-color: var(--accent); color: var(--accent); }
  .btn-primary:hover { background: rgba(0,229,255,0.2); }
  .btn-danger  { background: rgba(255,56,96,0.1);  border-color: var(--red);   color: var(--red); }
  .btn-danger:hover  { background: rgba(255,56,96,0.2); }
  .btn-warning { background: rgba(255,214,0,0.1);  border-color: var(--yellow); color: var(--yellow); }
  .btn-warning:hover { background: rgba(255,214,0,0.2); }
  .btn-success { background: rgba(0,255,136,0.1);  border-color: var(--green);  color: var(--green); }
  .btn-success:hover { background: rgba(0,255,136,0.2); }
  pre {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 16px; overflow-x: auto;
    font-size: 12px; line-height: 1.6;
    color: #94a3b8; white-space: pre-wrap;
  }
  .alert { padding: 12px 16px; border-radius: var(--radius); margin-bottom: 16px; font-size: 12px; }
  .alert-ok  { background: rgba(0,255,136,0.1); border: 1px solid var(--green); color: var(--green); }
  .alert-err { background: rgba(255,56,96,0.1);  border: 1px solid var(--red);   color: var(--red); }
  .mono { font-family: 'JetBrains Mono', monospace; }
  .inline-form { display: inline; }
  .edit-row td { background: rgba(0,229,255,0.03); }
  .path-input { min-width: 300px; }
</style>
</head>
<body>
<header>
  <a class="logo" href="/">1002x<span>OPERATOR</span><span class="sub">// samba</span></a>
  <nav>
    <a href="http://$HOST_IP:8080" class="home-link">⌂ Portal</a>
    <a href="/" class="active">⬡ Shares</a>
  </nav>
</header>
<main>
$body
</main>
</body>
</html>
HTML
}

# -------------------------------------------------------------------
# List shares from smb.conf
# -------------------------------------------------------------------
list_shares() {
    awk '
    /^\[/{
        name=$0; gsub(/\[|\]/,"",name)
        if(name!="global" && name!="homes" && name!="printers" && name!="print$")
            print name
    }' "$SMB" 2>/dev/null
}

get_share_path() {
    local share="$1"
    awk -v s="$share" '
    /^\[/{in_block=($0=="["s"]")}
    in_block && /path[ ]*=/{gsub(/.*path[ ]*=[ ]*/,""); gsub(/[ ]*$/,""); print; exit}
    ' "$SMB" 2>/dev/null
}

get_share_readonly() {
    local share="$1"
    awk -v s="$share" '
    /^\[/{in_block=($0=="["s"]")}
    in_block && /read only[ ]*=/{gsub(/.*read only[ ]*=[ ]*/,""); gsub(/[ ]*$/,""); print; exit}
    ' "$SMB" 2>/dev/null
}

get_share_guestok() {
    local share="$1"
    awk -v s="$share" '
    /^\[/{in_block=($0=="["s"]")}
    in_block && /guest ok[ ]*=/{gsub(/.*guest ok[ ]*=[ ]*/,""); gsub(/[ ]*$/,""); print; exit}
    ' "$SMB" 2>/dev/null
}

# -------------------------------------------------------------------
# PAGE: Shares
# -------------------------------------------------------------------
page_shares() {
    local msg="$1"
    local body=""
    body+="<h1>Samba Shares</h1>"
    [[ -n "$msg" ]] && body+="$msg"

    # Samba service status
    local svc_status svc_badge
    svc_status=$(systemctl is-active smbd 2>/dev/null)
    if [[ "$svc_status" == "active" ]]; then
        svc_badge='<span class="badge badge-green">active</span>'
    else
        svc_badge='<span class="badge badge-red">'$svc_status'</span>'
    fi

    body+="<div class='card'>
<h2>Service smbd $svc_badge</h2>
<div style='display:flex;gap:10px;flex-wrap:wrap'>
<form method='POST' action='/samba/action' class='inline-form'>
<input type='hidden' name='action' value='restart'>
<button class='btn btn-primary' type='submit'>↺ Restart</button>
</form>
<form method='POST' action='/samba/action' class='inline-form'>
<input type='hidden' name='action' value='reload'>
<button class='btn btn-warning' type='submit'>⟳ Reload</button>
</form>
</div></div>"

    # Shares table
    body+="<div class='card'><h2>Configured shares</h2>"
    local shares
    shares=$(list_shares)
    if [[ -n "$shares" ]]; then
        body+="<table><tr><th>Name</th><th>Path</th><th>Read only</th><th>Guest OK</th><th>Path existiert</th><th></th></tr>"
        while IFS= read -r share; do
            [[ -z "$share" ]] && continue
            local path ro guest path_exists_badge
            path=$(get_share_path "$share")
            ro=$(get_share_readonly "$share")
            guest=$(get_share_guestok "$share")
            if [[ -d "$path" ]]; then
                path_exists_badge='<span class="badge badge-green">✓</span>'
            else
                path_exists_badge='<span class="badge badge-red">✗</span>'
            fi
            local ro_badge guest_badge
            [[ "$ro" == "no" ]] && ro_badge='<span class="badge badge-green">nein</span>' || ro_badge='<span class="badge badge-red">ja</span>'
            [[ "$guest" == "yes" ]] && guest_badge='<span class="badge badge-green">ja</span>' || guest_badge='<span class="badge badge-red">nein</span>'

            body+="<tr>
<td class='mono'><strong>$share</strong></td>
<td class='mono'>$path</td>
<td>$ro_badge</td>
<td>$guest_badge</td>
<td>$path_exists_badge</td>
<td style='display:flex;gap:6px;align-items:center'>
  <form method='POST' action='/samba/edit' class='inline-form'>
    <input type='hidden' name='share' value='$share'>
    <input type='hidden' name='path_current' value='$path'>
    <button class='btn btn-warning' type='submit'>✎ Edit</button>
  </form>
  <form method='POST' action='/samba/delete' class='inline-form'>
    <input type='hidden' name='share' value='$share'>
    <button class='btn btn-danger' type='submit'>✕</button>
  </form>
</td></tr>"
        done <<< "$shares"
        body+="</table>"
    else
        body+="<p style='color:var(--muted)'>No shares configured.</p>"
    fi
    body+="</div>"

    # Add share form
    body+="<div class='card'><h2>Add share</h2>
<form method='POST' action='/samba/add'>
<div class='form-row'>
<div class='form-group'><label>Name</label>
<input type='text' name='name' placeholder='z.B. files'></div>
<div class='form-group'><label>Path</label>
<input type='text' name='path' placeholder='/srv/samba/files' class='path-input'></div>
<div class='form-group'><label>Read only</label>
<select name='readonly'>
<option value='no'>No</option>
<option value='yes'>Yes</option>
</select></div>
<div class='form-group'><label>Guest OK</label>
<select name='guest'>
<option value='yes'>Yes</option>
<option value='no'>No</option>
</select></div>
<button class='btn btn-primary' type='submit'>+ Add</button>
</div></form></div>"

    # smb.conf preview
    local conf_preview
    conf_preview=$(cat "$SMB" 2>/dev/null | tail -n 60)
    body+="<div class='card'><h2>smb.conf (last 60 lines)</h2><pre>$conf_preview</pre></div>"

    html_page "Samba Shares" "$body"
}

# -------------------------------------------------------------------
# PAGE: Edit share (inline)
# -------------------------------------------------------------------
page_edit() {
    local share="$1" path_current="$2" msg="$3"
    local body=""
    body+="<h1>Edit share: $share</h1>"
    [[ -n "$msg" ]] && body+="$msg"

    local ro guest
    ro=$(get_share_readonly "$share")
    guest=$(get_share_guestok "$share")

    body+="<div class='card'>
<form method='POST' action='/samba/edit/save'>
<input type='hidden' name='share' value='$share'>
<div class='form-row'>
<div class='form-group'><label>Path</label>
<input type='text' name='path' value='$path_current' class='path-input'></div>
<div class='form-group'><label>Read only</label>
<select name='readonly'>
<option value='no' $([ "$ro" = "no" ] && echo selected)>No</option>
<option value='yes' $([ "$ro" = "yes" ] && echo selected)>Yes</option>
</select></div>
<div class='form-group'><label>Guest OK</label>
<select name='guest'>
<option value='yes' $([ "$guest" = "yes" ] && echo selected)>Yes</option>
<option value='no'  $([ "$guest" = "no"  ] && echo selected)>No</option>
</select></div>
</div>
<div style='margin-top:16px;display:flex;gap:10px'>
<button class='btn btn-primary' type='submit'>✓ Save</button>
<a href='/' class='btn btn-danger'>✕ Cancel</a>
</div>
</form></div>"

    html_page "Edit Share" "$body"
}

# -------------------------------------------------------------------
# HTTP helpers
# -------------------------------------------------------------------
http_200() {
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
    echo "$1"
}
http_redirect() {
    printf "HTTP/1.1 302 Found\r\nLocation: $1\r\nConnection: close\r\n\r\n"
}
alert_ok()  { echo "<div class='alert alert-ok'>✓ $1</div>"; }
alert_err() { echo "<div class='alert alert-err'>✗ $1</div>"; }

samba_reload() {
    smbcontrol all reload-config 2>/dev/null || true
    systemctl restart smbd 2>/dev/null || true
}

# -------------------------------------------------------------------
# Handle request
# -------------------------------------------------------------------
handle_request() {
    local method path content_length body_raw
    read -r method path _
    path="${path//$'\r'/}"
    method="${method//$'\r'/}"

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break
        [[ "$line" =~ ^Content-Length:\ ([0-9]+) ]] && content_length="${BASH_REMATCH[1]}"
    done

    if [[ "$method" == "POST" && -n "$content_length" && "$content_length" -gt 0 ]]; then
        body_raw=$(dd bs=1 count="$content_length" 2>/dev/null)
    fi

    path="${path%%\?*}"

    case "$method $path" in

    "GET /")
        http_200 "$(page_shares)"
        ;;

    "POST /samba/action")
        local action
        action=$(get_post_value "$body_raw" "action")
        case "$action" in
            restart) systemctl restart smbd 2>/dev/null || true ;;
            reload)  samba_reload ;;
        esac
        http_redirect "/"
        ;;

    "POST /samba/add")
        local name path_val ro guest
        name=$(get_post_value "$body_raw" "name")
        path_val=$(get_post_value "$body_raw" "path")
        ro=$(get_post_value "$body_raw" "readonly")
        guest=$(get_post_value "$body_raw" "guest")
        name="${name//[^a-zA-Z0-9_-]/}"
        if [[ -z "$name" || -z "$path_val" ]]; then
            http_200 "$(page_shares "$(alert_err "Name und Path erforderlich")")"
        elif grep -q "^\[$name\]" "$SMB" 2>/dev/null; then
            http_200 "$(page_shares "$(alert_err "Share '$name' already exists")")"
        else
            mkdir -p "$path_val"
            cat >> "$SMB" <<SHAREEOF

[$name]
   path = $path_val
   browseable = yes
   read only = $ro
   guest ok = $guest
SHAREEOF
            samba_reload
            http_200 "$(page_shares "$(alert_ok "Share '$name' → $path_val created")")"
        fi
        ;;

    "POST /samba/edit")
        local share path_current
        share=$(get_post_value "$body_raw" "share")
        path_current=$(get_post_value "$body_raw" "path_current")
        http_200 "$(page_edit "$share" "$path_current")"
        ;;

    "POST /samba/edit/save")
        local share new_path ro guest
        share=$(get_post_value "$body_raw" "share")
        new_path=$(get_post_value "$body_raw" "path")
        ro=$(get_post_value "$body_raw" "readonly")
        guest=$(get_post_value "$body_raw" "guest")
        if [[ -z "$share" || -z "$new_path" ]]; then
            http_200 "$(page_shares "$(alert_err "Invalid input")")"
        else
            mkdir -p "$new_path"
            awk -v s="$share" -v p="$new_path" -v r="$ro" -v g="$guest" '
            /^\[/{in_block=($0=="["s"]")}
            in_block && /path[ ]*=/{$0="   path = " p}
            in_block && /read only[ ]*=/{$0="   read only = " r}
            in_block && /guest ok[ ]*=/{$0="   guest ok = " g}
            {print}
            ' "$SMB" > /tmp/smb_edit && mv /tmp/smb_edit "$SMB"
            samba_reload
            http_200 "$(page_shares "$(alert_ok "Share '$share' updated → $new_path")")"
        fi
        ;;

    "POST /samba/delete")
        local share
        share=$(get_post_value "$body_raw" "share")
        if [[ -n "$share" ]]; then
            awk -v s="$share" '
            BEGIN{skip=0}
            /^\[/{
                if($0=="["s"]"){skip=1; next}
                if(skip==1){skip=0}
            }
            skip==0{print}
            ' "$SMB" > /tmp/smb_del && mv /tmp/smb_del "$SMB"
            samba_reload
            http_200 "$(page_shares "$(alert_ok "Share '$share' deleted")")"
        else
            http_redirect "/"
        fi
        ;;

    *)
        printf "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n404"
        ;;
    esac
}

# -------------------------------------------------------------------
# Main loop
# -------------------------------------------------------------------
log "Starting Samba WebUI on port $PORT"
log "Open: http://$(ip -4 addr show dev $(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2) 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1):$PORT"

FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap "rm -f '$FIFO'" EXIT

while true; do
    handle_request < "$FIFO" | nc -q 1 -l -p "$PORT" > "$FIFO" 2>/dev/null ||     handle_request < "$FIFO" | nc -l -p "$PORT" > "$FIFO" 2>/dev/null ||     handle_request < "$FIFO" | nc -l "$PORT" > "$FIFO" 2>/dev/null
done
