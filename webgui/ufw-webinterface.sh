#!/bin/bash
# ufw-webinterface.sh – 1002xOPERATOR UFW Web Dashboard
# Port 8083 - Full interactive with block/allow/delete

PORT="${1:-8083}"
log() { echo "[ufw-web] $1"; }

get_lan_ip() {
    local lan_if=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    local ip=$(ip -4 addr show dev "$lan_if" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

get_rules_html() {
    local recent_rules_html=""
    local count=0
    while IFS= read -r line; do
        [[ "$line" =~ ^To || "$line" =~ ^-- || -z "$line" ]] && continue
        if [[ -n "$line" && ! "$line" =~ ^Status ]]; then
            local to action from
            to=$(echo "$line" | awk '{print $1}')
            action=$(echo "$line" | awk '{print $2}')
            from=$(echo "$line" | awk '{print $3}')
            if [[ -n "$to" && -n "$action" ]]; then
                recent_rules_html+="<div class='rule-item'><span class='rule-port'>$to</span> <span class='rule-action'>$action</span> <span class='rule-num'>← $from</span></div>"
                ((count++))
                [[ $count -ge 5 ]] && break
            fi
        fi
    done < <(sudo ufw status 2>/dev/null)
    echo "$recent_rules_html"
}

handle_request() {
    local method path query_string
    read -r method path query_string
    path="${path//$'\r'/}"
    method="${method//$'\r'/}"
    while IFS= read -r line; do line="${line%$'\r'}"; [[ -z "$line" ]] && break; done

    local HOST_IP=$(get_lan_ip)
    local post_data=""
    [[ "$method" == "POST" ]] && read -r post_data

    local message=""
    if [[ -n "$post_data" ]]; then
        local action=$(echo "$post_data" | grep -oP 'action=\K[^&]+')
        local port=$(echo "$post_data" | grep -oP 'port=\K[^&]+')
        local proto=$(echo "$post_data" | grep -oP 'protocol=\K[^&]+')
        local ip=$(echo "$post_data" | grep -oP 'ip=\K[^&]+' | sed 's/%2F/\//g')
        local rule=$(echo "$post_data" | grep -oP 'rule=\K[^&]+' | sed 's/%2F/\//g')
        local policy=$(echo "$post_data" | grep -oP 'policy=\K[^&]+')
        local level=$(echo "$post_data" | grep -oP 'level=\K[^&]+')

        case "$action" in
            add_rule)
                [[ -n "$port" && -n "$proto" ]] && {
                    message="<div class='success'>✓ Allowed: $port/$proto</div>"
                    sudo ufw allow "$port/$proto" 2>/dev/null
                }
                ;;
            block_rule)
                [[ -n "$port" && -n "$proto" ]] && {
                    message="<div class='success'>✓ Blocked: $port/$proto</div>"
                    sudo ufw deny "$port/$proto" 2>/dev/null
                }
                ;;
            block_ip)
                [[ -n "$ip" ]] && {
                    message="<div class='success'>✓ IP Blocked: $ip</div>"
                    sudo ufw deny from "$ip" 2>/dev/null
                }
                ;;
            delete_rule)
                [[ -n "$rule" ]] && {
                    message="<div class='success'>✓ Deleted: $rule</div>"
                    sudo ufw delete allow "$rule" 2>/dev/null || sudo ufw delete deny "$rule" 2>/dev/null
                }
                ;;
            set_policy)
                [[ -n "$policy" ]] && {
                    message="<div class='success'>✓ Policy: $policy</div>"
                    sudo ufw default "$policy" incoming 2>/dev/null
                }
                ;;
            set_logging)
                [[ -n "$level" ]] && {
                    message="<div class='success'>✓ Logging: $level</div>"
                    sudo ufw logging "$level" 2>/dev/null
                }
                ;;
        esac
    fi

    local ufw_status=$(sudo ufw status 2>/dev/null | head -1 | awk '{print $2}')
    local ufw_color="$([[ "$ufw_status" == "active" ]] && echo "#00ff88" || echo "#ff3860")"
    local rule_count=$(sudo ufw status 2>/dev/null | tail -n +4 | grep -v "^--" | grep -v "^$" | wc -l)
    local logging_level=$(sudo ufw logging 2>/dev/null | grep -oP 'level: \K\w+' || echo "medium")
    local current_time=$(date '+%Y-%m-%d %H:%M:%S')
    local recent_rules_html=$(get_rules_html)

    printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
    cat <<HTML
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>1002xOPERATOR - UFW Dashboard</title>
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
  body::after {
    content: '';
    position: fixed; inset: 0;
    background-image: linear-gradient(rgba(0,229,255,0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(0,229,255,0.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
  }
  .container { position: relative; z-index: 1; width: 100%; max-width: 1200px; }
  .header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 40px; }
  .hero { flex: 1; }
  .hero-label { font-size: 11px; letter-spacing: 4px; text-transform: uppercase; color: var(--muted); margin-bottom: 12px; }
  .hero-title { font-family: 'Syne', sans-serif; font-size: 48px; font-weight: 900; line-height: 1; color: var(--accent); letter-spacing: -2px; }
  .hero-title span { color: var(--accent2); }
  .status-badge { display: flex; align-items: center; gap: 8px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 12px 16px; font-size: 12px; }
  .status-dot { width: 10px; height: 10px; border-radius: 50%; animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100%{ opacity:1; } 50%{ opacity:0.4; } }
  .grid { display: grid; grid-template-columns: 1fr 1fr 1fr 1fr 1fr; gap: 20px; margin-bottom: 40px; }
  @media(max-width:1200px) { .grid { grid-template-columns: 1fr 1fr; } }
  @media(max-width:600px) { .grid { grid-template-columns: 1fr; } }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 20px; }
  .card-title { font-family: 'Syne', sans-serif; font-size: 14px; font-weight: 800; color: var(--accent); margin-bottom: 16px; padding-bottom: 12px; border-bottom: 1px solid var(--border); }
  .stat-row { display: flex; justify-content: space-between; padding: 8px 0; font-size: 11px; border-bottom: 1px solid rgba(255,255,255,0.05); }
  .stat-label { color: var(--muted); }
  .stat-value { color: var(--accent); font-weight: 600; }
  .form-group { margin-bottom: 12px; }
  .form-group label { display: block; font-size: 10px; color: var(--muted); margin-bottom: 4px; }
  .form-group input, .form-group select { width: 100%; background: rgba(0,229,255,0.05); border: 1px solid var(--border); color: var(--text); padding: 8px; border-radius: 4px; font-family: 'JetBrains Mono', monospace; font-size: 11px; }
  .form-group input:focus, .form-group select:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 2px rgba(0,229,255,0.1); }
  .submit-btn { width: 100%; background: rgba(0,229,255,0.1); border: 1px solid var(--accent); color: var(--accent); padding: 10px; border-radius: 4px; font-size: 11px; cursor: pointer; transition: all 0.2s; font-family: 'JetBrains Mono', monospace; font-weight: 600; }
  .submit-btn:hover { background: var(--accent); color: var(--bg); }
  .submit-btn.deny { background: rgba(255,56,96,0.1); border-color: var(--red); color: var(--red); }
  .submit-btn.deny:hover { background: var(--red); color: var(--bg); }
  .rule-item { display: flex; gap: 12px; align-items: center; padding: 8px; background: rgba(0,229,255,0.05); border-radius: 4px; margin-bottom: 6px; font-size: 10px; }
  .success, .error { padding: 10px; border-radius: 4px; margin-bottom: 12px; font-size: 11px; }
  .success { background: rgba(0,255,136,0.1); border: 1px solid var(--green); color: var(--green); }
  .back-btn { background: rgba(255,107,53,0.1); border: 1px solid var(--accent2); color: var(--accent2); padding: 10px 16px; border-radius: 4px; font-size: 11px; text-decoration: none; display: inline-block; transition: all 0.2s; }
  .back-btn:hover { background: var(--accent2); color: var(--bg); }
  .footer { text-align: center; font-size: 11px; color: var(--muted); margin-top: 40px; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="hero">
      <div class="hero-label">Firewall Dashboard</div>
      <div class="hero-title">UFW<span>CONTROL</span></div>
    </div>
    <div class="status-badge">
      <div class="status-dot" style="background: $ufw_color"></div>
      <span>UFW: $ufw_status</span>
    </div>
  </div>

  $message

  <div class="grid">
    <div class="card">
      <div class="card-title">Status</div>
      <div class="stat-row"><span class="stat-label">UFW:</span><span class="stat-value">$ufw_status</span></div>
      <div class="stat-row"><span class="stat-label">Rules:</span><span class="stat-value">$rule_count</span></div>
      <div class="stat-row"><span class="stat-label">Logging:</span><span class="stat-value">$logging_level</span></div>
    </div>

    <div class="card">
      <div class="card-title">Allow Port</div>
      <form method="POST">
        <input type="hidden" name="action" value="add_rule">
        <div class="form-group"><label>Port</label><input type="number" name="port" min="1" max="65535" required></div>
        <div class="form-group"><label>Protocol</label><select name="protocol" required><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
        <button class="submit-btn" type="submit">✓ Allow</button>
      </form>
    </div>

    <div class="card">
      <div class="card-title">Block Port</div>
      <form method="POST">
        <input type="hidden" name="action" value="block_rule">
        <div class="form-group"><label>Port</label><input type="number" name="port" min="1" max="65535" required></div>
        <div class="form-group"><label>Protocol</label><select name="protocol" required><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
        <button class="submit-btn deny" type="submit">✗ Block</button>
      </form>
    </div>

    <div class="card">
      <div class="card-title">Block IP</div>
      <form method="POST">
        <input type="hidden" name="action" value="block_ip">
        <div class="form-group"><label>IP Address</label><input type="text" name="ip" placeholder="192.168.1.1" required></div>
        <button class="submit-btn deny" type="submit">✗ Block IP</button>
      </form>
    </div>

    <div class="card">
      <div class="card-title">Delete Rule</div>
      <form method="POST">
        <input type="hidden" name="action" value="delete_rule">
        <div class="form-group"><label>Rule</label><input type="text" name="rule" placeholder="22/tcp" required></div>
        <button class="submit-btn deny" type="submit">✗ Delete</button>
      </form>
    </div>
  </div>

  <div class="grid" style="grid-template-columns: 1fr 1fr;">
    <div class="card">
      <div class="card-title">Settings</div>
      <form method="POST">
        <input type="hidden" name="action" value="set_policy">
        <div class="form-group"><label>Incoming Policy</label><select name="policy" required><option value="deny">DENY</option><option value="allow">ALLOW</option><option value="reject">REJECT</option></select></div>
        <button class="submit-btn" type="submit">✓ Set</button>
      </form>
      <form method="POST" style="margin-top: 12px;">
        <input type="hidden" name="action" value="set_logging">
        <div class="form-group"><label>Logging Level</label><select name="level" required><option value="off">Off</option><option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option></select></div>
        <button class="submit-btn" type="submit">✓ Set</button>
      </form>
    </div>

    <div class="card">
      <div class="card-title">Recent Rules (Last 5)</div>
      $recent_rules_html
    </div>
  </div>

  <a href="http://$HOST_IP:8080" class="back-btn">← Back to Portal</a>
  <div class="footer">Auto-refresh every 30s</div>
</div>
</body>
</html>
HTML
}

log "Starting UFW Dashboard on port $PORT"
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap "rm -f '$FIFO'" EXIT

while true; do
    handle_request < "$FIFO" | nc -q 1 -l -p "$PORT" > "$FIFO" 2>/dev/null || \
    handle_request < "$FIFO" | nc -l -p "$PORT" > "$FIFO" 2>/dev/null || \
    handle_request < "$FIFO" | nc -l "$PORT" > "$FIFO" 2>/dev/null
done
