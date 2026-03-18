#!/bin/bash
# portal.sh – 1002xOPERATOR Portal Startseite
# Port 8080
#
# Requires: socat (installed automatically via apt if missing)
# Fallback: nc (Access Control disabled in nc mode)

PORT="${1:-8080}"
ACCESS_CONF="/etc/1002xOPERATOR/webgui/access.conf"
SCRIPT_PATH="$(realpath "$0")"

log() { echo "[portal] $1"; }

# ─── socat Bootstrap ──────────────────────────────────────────────────────────

ensure_socat() {
    if command -v socat &>/dev/null; then echo "socat"; return 0; fi
    log "socat not found – attempting install via apt..."
    if apt-get install -y socat &>/dev/null; then
        log "socat installed successfully."
        echo "socat"; return 0
    fi
    log "WARNING: socat install failed. Falling back to nc – Access Control disabled."
    echo "nc"; return 1
}

# ─── Access Control ───────────────────────────────────────────────────────────

# Pure-bash IPv4 CIDR membership check
ip_in_cidr() {
    local ip="$1" cidr="$2"
    local net="${cidr%/*}" bits="${cidr#*/}"
    [[ "$bits" == "$cidr" ]] && bits=32
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$ip"
    read -r n1 n2 n3 n4 <<< "$net"
    local ip_int=$(( (i1<<24)|(i2<<16)|(i3<<8)|i4 ))
    local net_int=$(( (n1<<24)|(n2<<16)|(n3<<8)|n4 ))
    local mask=$(( 0xFFFFFFFF << (32-bits) & 0xFFFFFFFF ))
    (( (ip_int & mask) == (net_int & mask) ))
}

load_access_conf() {
    mkdir -p "$(dirname "$ACCESS_CONF")"
    if [[ ! -f "$ACCESS_CONF" ]]; then
        echo "# 1002xOPERATOR WebGUI Access Control" > "$ACCESS_CONF"
        echo "# Format: one subnet/CIDR per line that is ALLOWED" >> "$ACCESS_CONF"
        echo "# Example: 10.2.0.0/24" >> "$ACCESS_CONF"
        echo "DEFAULT=allow" >> "$ACCESS_CONF"
        return
    fi
    # Migrate bare IPs (no slash) to their interface CIDR automatically
    local tmp changed=0
    tmp=$(mktemp)
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # bare IP — find matching interface CIDR
            local found=""
            while IFS= read -r iface; do
                [[ "$iface" == "lo" ]] && continue
                while IFS= read -r cidr; do
                    [[ -z "$cidr" ]] && continue
                    local net="${cidr%/*}"
                    [[ "$net" == "$line" || "$line" == "$net" ]] && { found="$cidr"; break 2; }
                    # check if bare IP is in this subnet
                    ip_in_cidr "$line" "$cidr" && { found="$cidr"; break 2; }
                done < <(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}')
            done < <(ls /sys/class/net/)
            if [[ -n "$found" ]]; then
                echo "$found" >> "$tmp"
                changed=1
            else
                echo "$line" >> "$tmp"
            fi
        else
            echo "$line" >> "$tmp"
        fi
    done < "$ACCESS_CONF"
    [[ "$changed" -eq 1 ]] && cp "$tmp" "$ACCESS_CONF"
    rm -f "$tmp"
}

# check_access <src_ip> → 0=allow 1=deny
check_access() {
    local src_ip="$1"
    load_access_conf

    local default
    default=$(grep -E '^DEFAULT=' "$ACCESS_CONF" | tail -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
    [[ -z "$default" ]] && default="allow"

    # Collect allowed IPs
    local allowed=()
    while IFS= read -r line; do
        [[ "$line" =~ ^#      ]] && continue
        [[ "$line" =~ ^DEFAULT ]] && continue
        [[ -z "$line"         ]] && continue
        allowed+=("$line")
    done < "$ACCESS_CONF"

    # No rules = use default
    if [[ ${#allowed[@]} -eq 0 ]]; then
        [[ "$default" == "allow" ]] && return 0 || return 1
    fi

    for cidr in "${allowed[@]}"; do
        ip_in_cidr "$src_ip" "$cidr" && return 0
    done
    return 1
}

# ─── HTTP helpers ─────────────────────────────────────────────────────────────

send_403() {
    printf "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
    cat <<'HTML'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>403 – Access Denied</title>
<style>
  body{background:#0a0c10;color:#ff3860;font-family:monospace;
       display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
  .box{text-align:center}
  .t{font-size:48px;font-weight:900;margin-bottom:12px}
  .s{color:#64748b;font-size:13px}
</style></head><body>
<div class="box"><div class="t">⛔ 403</div>
<div class="s">Your IP is not allowed to access this portal.</div></div>
</body></html>
HTML
}

send_redirect() {
    printf "HTTP/1.1 302 Found\r\nLocation: %s\r\nConnection: close\r\n\r\n" "$1"
}

# ─── Access Settings Page ─────────────────────────────────────────────────────

handle_access_settings() {
    local method="$1" post_body="$2" client_ip="$3"
    load_access_conf

    if [[ "$method" == "POST" ]]; then
        local decoded="${post_body//+/ }"
        decoded=$(printf '%b' "${decoded//%/\\x}")

        local new_default
        new_default=$(tr '&' '\n' <<< "$decoded" | grep '^default=' | cut -d= -f2)
        [[ -z "$new_default" ]] && new_default="allow"

        mkdir -p "$(dirname "$ACCESS_CONF")"
        {
            echo "# 1002xOPERATOR WebGUI Access Control"
            echo "# Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# Allowed IPs (one per line). Empty = use DEFAULT."
            echo "DEFAULT=${new_default}"
            echo ""
            tr '&' '\n' <<< "$decoded" | grep '^ip=' | cut -d= -f2
        } > "$ACCESS_CONF"

        send_redirect "/access?saved=1"
        return
    fi

    # Build checkbox list of all IPs on all interfaces
    local ip_rows=""
    while IFS= read -r iface; do
        [[ "$iface" == "lo" ]] && continue
        local state type_label type_color
        state=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "?")

        if ip link show "$iface" 2>/dev/null | grep -q 'link/ether'; then
            if ip route show default dev "$iface" 2>/dev/null | grep -q .; then
                type_label="WAN"; type_color="#ff6b35"
            else
                type_label="LAN"; type_color="#00e5ff"
            fi
        elif [[ "$iface" == wlan* || "$iface" == wlp* ]]; then
            type_label="WIFI"; type_color="#facc15"
        elif [[ "$iface" == tun* || "$iface" == tap* || "$iface" == wg* ]]; then
            type_label="VPN";  type_color="#a855f7"
        else
            type_label="OTHER"; type_color="#64748b"
        fi

        local state_dot="#00ff88"
        [[ "$state" != "up" ]] && state_dot="#ff3860"

        while IFS= read -r ip4; do
            [[ -z "$ip4" ]] && continue
            local bare="${ip4%/*}"
            local checked=""
            grep -qxF "$ip4" "$ACCESS_CONF" && checked="checked"
            local is_me=""
            ip_in_cidr "$client_ip" "$ip4" && is_me=" <span class='you'>(you are here)</span>"
            ip_rows+="
            <label class='ip-row'>
              <input type='checkbox' name='ip' value='${ip4}' ${checked}>
              <span class='ip-addr'>${ip4}</span>
              <span class='badge' style='--bc:${type_color}'>${type_label}</span>
              <span class='iface-tag'>${iface}</span>
              <span class='dot-sm' style='background:${state_dot}'></span>
              ${is_me}
            </label>"
        done < <(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}')
    done < <(ls /sys/class/net/ 2>/dev/null)

    local current_default
    current_default=$(grep -E '^DEFAULT=' "$ACCESS_CONF" | tail -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
    [[ -z "$current_default" ]] && current_default="allow"
    local allow_def="" deny_def=""
    [[ "$current_default" == "allow" ]] && allow_def="checked"
    [[ "$current_default" == "deny"  ]] && deny_def="checked"

    local nc_warn=""
    [[ "${TRANSPORT:-socat}" == "nc" ]] && nc_warn="
    <div class='warn-banner'>⚠️ Running in <strong>nc fallback mode</strong> — socat unavailable. Access Control is <strong>disabled</strong>. Install socat (<code>apt install socat</code>) and restart.</div>"

    printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Access Control – 1002xOPERATOR</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Syne:wght@700;800;900&display=swap');
  :root{--bg:#0a0c10;--surface:#111318;--border:#1e2230;--accent:#00e5ff;--accent2:#ff6b35;--green:#00ff88;--red:#ff3860;--text:#e2e8f0;--muted:#64748b}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;min-height:100vh;padding:40px 20px}
  body::after{content:'';position:fixed;inset:0;background-image:linear-gradient(rgba(0,229,255,.03) 1px,transparent 1px),linear-gradient(90deg,rgba(0,229,255,.03) 1px,transparent 1px);background-size:40px 40px;pointer-events:none;z-index:0}
  .wrap{position:relative;z-index:1;max-width:700px;margin:0 auto}
  .topbar{display:flex;align-items:center;gap:20px;margin-bottom:40px;flex-wrap:wrap}
  .back-btn{font-family:'JetBrains Mono',monospace;font-size:12px;color:var(--muted);border:1px solid var(--border);background:var(--surface);padding:8px 14px;border-radius:6px;text-decoration:none;transition:all .2s}
  .back-btn:hover{color:var(--accent);border-color:var(--accent)}
  .page-title{font-family:'Syne',sans-serif;font-size:26px;font-weight:900;color:var(--accent)}
  .page-title span{color:var(--accent2)}
  .page-sub{font-size:11px;color:var(--muted);letter-spacing:2px;margin-top:2px}
  .warn-banner{background:rgba(255,107,53,.12);border:1px solid rgba(255,107,53,.4);border-radius:8px;padding:14px 18px;margin-bottom:20px;font-size:12px;color:#ffb38a;line-height:1.7}
  .warn-banner code{color:var(--accent)}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:8px;margin-bottom:20px;overflow:hidden}
  .card-head{padding:14px 20px;border-bottom:1px solid var(--border);font-size:10px;letter-spacing:3px;text-transform:uppercase;color:var(--muted);display:flex;align-items:center;gap:10px}
  .accent-line{width:3px;height:14px;border-radius:2px;background:var(--accent);flex-shrink:0}
  .card-body{padding:20px}
  /* Default policy seg */
  .seg{display:inline-flex;border:1px solid var(--border);border-radius:6px;overflow:hidden}
  .seg label{padding:9px 22px;font-size:12px;cursor:pointer;transition:all .2s;user-select:none;color:var(--muted)}
  .seg label:first-child{border-right:1px solid var(--border)}
  .seg input{display:none}
  .seg label:has(input[value="allow"]:checked){background:rgba(0,255,136,.18);color:var(--green);font-weight:700}
  .seg label:has(input[value="deny"]:checked){background:rgba(255,56,96,.18);color:var(--red);font-weight:700}
  .policy-desc{font-size:11px;color:var(--muted);margin-top:10px;line-height:1.6}
  /* IP checkbox rows */
  .ip-list{display:flex;flex-direction:column;gap:6px}
  .ip-row{display:flex;align-items:center;gap:10px;padding:10px 12px;border:1px solid var(--border);border-radius:6px;cursor:pointer;transition:all .15s;user-select:none}
  .ip-row:hover{border-color:var(--accent);background:rgba(0,229,255,.04)}
  .ip-row:has(input:checked){border-color:var(--green);background:rgba(0,255,136,.06)}
  .ip-row input{accent-color:var(--green);width:15px;height:15px;cursor:pointer;flex-shrink:0}
  .ip-addr{color:var(--text);font-weight:600;font-size:13px;min-width:120px}
  .ip-cidr{color:var(--muted);font-size:11px}
  .badge{font-size:10px;padding:2px 7px;border-radius:3px;border:1px solid var(--bc,var(--border));color:var(--bc,var(--muted));background:rgba(255,255,255,.03)}
  .iface-tag{color:var(--muted);font-size:11px}
  .dot-sm{display:inline-block;width:7px;height:7px;border-radius:50%;flex-shrink:0}
  .you{color:var(--accent);font-size:11px}
  /* Save */
  .save-row{display:flex;justify-content:flex-end;margin-top:4px}
  .save-btn{font-family:'JetBrains Mono',monospace;background:var(--accent);color:#0a0c10;border:none;padding:12px 32px;font-size:13px;font-weight:700;border-radius:6px;cursor:pointer;letter-spacing:1px;transition:all .2s}
  .save-btn:hover{background:#33edff;transform:translateY(-1px)}
  .toast{position:fixed;top:24px;right:24px;background:var(--green);color:#0a0c10;font-size:13px;font-weight:700;padding:12px 24px;border-radius:6px;animation:fadeout 3.5s forwards;z-index:999}
  @keyframes fadeout{0%{opacity:1}70%{opacity:1}100%{opacity:0;pointer-events:none}}
  .hint{font-size:11px;color:var(--muted);line-height:1.8;border-left:2px solid var(--border);padding-left:12px}
  .hint code{color:var(--accent)}
</style>
</head>
<body>
<div class="wrap">
  <div class="topbar">
    <a href="/" class="back-btn">← Back to Portal</a>
    <div>
      <div class="page-title">Access <span>Control</span></div>
      <div class="page-sub">// WEBGUI IP ALLOWLIST</div>
    </div>
  </div>

  ${nc_warn}

  <form method="POST" action="/access">

    <!-- Default Policy -->
    <div class="card">
      <div class="card-head"><div class="accent-line"></div> Default Policy</div>
      <div class="card-body">
        <div class="seg">
          <label><input type="radio" name="default" value="allow" ${allow_def}> ALLOW all</label>
          <label><input type="radio" name="default" value="deny"  ${deny_def}>  DENY all</label>
        </div>
        <div class="policy-desc">
          Applied when an IP is <strong>not checked</strong> in the list below.<br>
          Set to <strong>DENY all</strong> to restrict access to checked IPs only.
        </div>
      </div>
    </div>

    <!-- IP Allowlist -->
    <div class="card">
      <div class="card-head"><div class="accent-line"></div> Allowed IPs</div>
      <div class="card-body">
        <div class="ip-list">
          ${ip_rows}
        </div>
      </div>
    </div>

    <!-- Config hint -->
    <div class="card">
      <div class="card-head"><div class="accent-line"></div> Configuration File</div>
      <div class="card-body">
        <div class="hint">
          Saved to <code>${ACCESS_CONF}</code><br>
          One subnet per line in CIDR notation. <code>DEFAULT=allow</code> or <code>DEFAULT=deny</code> sets the fallback.<br>
          Example: <code>10.2.0.0/24</code> allows the entire subnet.
        </div>
      </div>
    </div>

    <div class="save-row">
      <button type="submit" class="save-btn">SAVE</button>
    </div>
  </form>
</div>
<script>
  if (location.search.includes('saved=1')) {
    const t = document.createElement('div');
    t.className = 'toast';
    t.textContent = '✓ Saved';
    document.body.appendChild(t);
    history.replaceState(null, '', location.pathname);
  }
</script>
</body></html>
HTML
}

# ─── Main Request Handler ─────────────────────────────────────────────────────

handle_request() {
    local method path qs
    read -r method path _
    path="${path//$'\r'/}"
    method="${method//$'\r'/}"
    qs="${path#*\?}"; [[ "$qs" == "$path" ]] && qs=""
    path="${path%%\?*}"

    local content_length=0
    while IFS= read -r line; do
        line="${line%$'\r'}"; [[ -z "$line" ]] && break
        if [[ "$line" =~ ^[Cc]ontent-[Ll]ength:[[:space:]]*([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done

    local post_body=""
    if [[ "$method" == "POST" && "$content_length" -gt 0 ]]; then
        post_body=$(dd bs=1 count="$content_length" 2>/dev/null)
    fi
    [[ "$method" == "GET" && -n "$qs" ]] && post_body="$qs"

    # ── Client IP ─────────────────────────────────────────────────────────────
    local CLIENT_IP="${SOCAT_PEERADDR:-127.0.0.1}"
    CLIENT_IP="${CLIENT_IP#::ffff:}"

    # ── Own IP: first ALLOWED IP from conf, else DHCP iface, else any ─────────
    local HOST_IP=""
    load_access_conf
    local _default
    _default=$(grep -E '^DEFAULT=' "$ACCESS_CONF" | tail -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')

    if [[ "$_default" == "deny" ]]; then
        # Find a local IP that falls inside the first allowed CIDR
        while IFS= read -r _allowed_cidr; do
            [[ "$_allowed_cidr" =~ ^#      ]] && continue
            [[ "$_allowed_cidr" =~ ^DEFAULT ]] && continue
            [[ -z "$_allowed_cidr"          ]] && continue
            while IFS= read -r _iface; do
                [[ "$_iface" == "lo" ]] && continue
                while IFS= read -r _local_cidr; do
                    [[ -z "$_local_cidr" ]] && continue
                    local _local_ip="${_local_cidr%/*}"
                    if ip_in_cidr "$_local_ip" "$_allowed_cidr"; then
                        HOST_IP="$_local_ip"
                        break 3
                    fi
                done < <(ip -4 addr show dev "$_iface" 2>/dev/null | awk '/inet / {print $2}')
            done < <(ls /sys/class/net/)
        done < "$ACCESS_CONF"
    fi

    # Fallback: DHCP interface IP
    if [[ -z "$HOST_IP" ]]; then
        local LAN_IF
        LAN_IF=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
        HOST_IP=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    fi
    [[ -z "$HOST_IP" ]] && HOST_IP=$(hostname -I | awk '{print $1}')

    # ── Access check ──────────────────────────────────────────────────────────
    if [[ "${TRANSPORT:-socat}" == "socat" ]]; then
        if ! check_access "$CLIENT_IP"; then
            send_403; return
        fi
    fi

    # ── Router ────────────────────────────────────────────────────────────────
    if [[ "$path" == "/access" ]]; then
        handle_access_settings "$method" "$post_body" "$CLIENT_IP"
        return
    fi

    # ── Portal main page ──────────────────────────────────────────────────────
    local wan_status samba_status dhcp_status ufw_status
    wan_status=$(systemctl  is-active wan-failover    2>/dev/null)
    samba_status=$(systemctl is-active smbd           2>/dev/null)
    dhcp_status=$(systemctl  is-active isc-dhcp-server 2>/dev/null)
    ufw_status=$(sudo ufw status 2>/dev/null | head -1 | awk '{print $2}')

    local wan_color samba_color dhcp_color ufw_color
    [[ "$wan_status"   == "active" ]] && wan_color="#00ff88"   || wan_color="#ff3860"
    [[ "$samba_status" == "active" ]] && samba_color="#00ff88" || samba_color="#ff3860"
    [[ "$dhcp_status"  == "active" ]] && dhcp_color="#00ff88"  || dhcp_color="#ff3860"
    [[ "$ufw_status"   == "active" ]] && ufw_color="#00ff88"   || ufw_color="#ff3860"

    local wan_ifaces=""
    local priority_file="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
    local state_file="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
    if [[ -f "$priority_file" ]]; then
        wan_list=$(tail -n1 "$priority_file")
        for iface in $wan_list; do
            local ip state suppressed dot_color
            ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet/ {print $2}' | head -n1)
            state=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "?")
            grep -q "^SUPPRESSED $iface " "$state_file" 2>/dev/null && suppressed=1 || suppressed=0
            if   [[ "$suppressed" -eq 1 ]]; then dot_color="#ff3860"
            elif [[ "$state" == "up"    ]]; then dot_color="#00ff88"
            else dot_color="#ff3860"; fi
            wan_ifaces+="<div class='iface-pill'><span class='dot' style='background:$dot_color'></span><span class='iface-name'>$iface</span><span class='iface-ip'>${ip:-no ip}</span></div>"
        done
    fi

    local nc_banner=""
    [[ "${TRANSPORT:-socat}" == "nc" ]] && nc_banner="
  <div style='background:rgba(255,107,53,.1);border:1px solid rgba(255,107,53,.35);border-radius:6px;padding:10px 16px;margin-bottom:28px;font-size:11px;color:#ffb38a;text-align:center'>
    ⚠️ Access Control inactive — <code style='color:#00e5ff'>apt install socat</code> and restart to enable.
  </div>"

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
  :root{--bg:#0a0c10;--surface:#111318;--border:#1e2230;--accent:#00e5ff;--accent2:#ff6b35;--green:#00ff88;--red:#ff3860;--text:#e2e8f0;--muted:#64748b}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:40px 20px}
  body::before{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,229,255,.012) 2px,rgba(0,229,255,.012) 4px);pointer-events:none}
  body::after{content:'';position:fixed;inset:0;background-image:linear-gradient(rgba(0,229,255,.03) 1px,transparent 1px),linear-gradient(90deg,rgba(0,229,255,.03) 1px,transparent 1px);background-size:40px 40px;pointer-events:none}
  .container{position:relative;z-index:1;width:100%;max-width:900px}
  .hero{text-align:center;margin-bottom:60px}
  .hero-label{font-size:11px;letter-spacing:4px;text-transform:uppercase;color:var(--muted);margin-bottom:12px}
  .hero-title{font-family:'Syne',sans-serif;font-size:clamp(42px,8vw,80px);font-weight:900;line-height:1;color:var(--accent);letter-spacing:-2px}
  .hero-title span{color:var(--accent2)}
  .hero-sub{font-size:12px;color:var(--muted);margin-top:12px;letter-spacing:2px}
  .status-bar{display:flex;gap:20px;justify-content:center;flex-wrap:wrap;margin-bottom:48px}
  .status-item{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--muted)}
  .status-dot{width:8px;height:8px;border-radius:50%;animation:pulse 2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
  .iface-pills{display:flex;gap:10px;justify-content:center;flex-wrap:wrap;margin-bottom:48px}
  .iface-pill{display:flex;align-items:center;gap:8px;background:var(--surface);border:1px solid var(--border);border-radius:20px;padding:6px 14px;font-size:12px}
  .dot{width:7px;height:7px;border-radius:50%}
  .iface-name{color:var(--accent);font-weight:600}
  .iface-ip{color:var(--muted)}
  .modules{display:grid;grid-template-columns:1fr 1fr 1fr;gap:20px}
  @media(max-width:900px){.modules{grid-template-columns:1fr 1fr}}
  @media(max-width:600px){.modules{grid-template-columns:1fr}}
  .module{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:28px;text-decoration:none;color:var(--text);transition:all .2s;position:relative;overflow:hidden}
  .module::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:var(--module-color,var(--accent));opacity:.6;transition:opacity .2s}
  .module:hover{border-color:var(--module-color,var(--accent));transform:translateY(-2px)}
  .module:hover::before{opacity:1}
  .module-icon{font-size:28px;margin-bottom:12px;display:block}
  .module-title{font-family:'Syne',sans-serif;font-size:18px;font-weight:800;color:var(--module-color,var(--accent));margin-bottom:6px}
  .module-desc{font-size:12px;color:var(--muted);line-height:1.6}
  .module-port{position:absolute;top:16px;right:16px;font-size:10px;color:var(--muted);border:1px solid var(--border);padding:2px 8px;border-radius:3px}
  .module-tags{display:flex;gap:6px;flex-wrap:wrap;margin-top:12px}
  .tag{font-size:10px;padding:2px 8px;border-radius:3px;background:rgba(255,255,255,.05);color:var(--muted)}
  .footer{text-align:center;margin-top:48px;font-size:11px;color:var(--muted)}
  .footer span{color:var(--accent)}
  .access-btn{position:fixed;bottom:24px;right:24px;display:flex;align-items:center;gap:8px;font-family:'JetBrains Mono',monospace;font-size:11px;letter-spacing:1px;color:var(--muted);border:1px solid var(--border);background:var(--surface);padding:8px 14px;border-radius:6px;text-decoration:none;transition:all .2s;z-index:100}
  .access-btn:hover{color:var(--accent);border-color:var(--accent)}
</style>
</head>
<body>
<div class="container">
  <div class="hero">
    <div class="hero-label">Management Portal</div>
    <div class="hero-title">1002x<span>OPERATOR</span></div>
    <div class="hero-sub">// NETWORK &amp; SERVICES CONTROL</div>
  </div>

  ${nc_banner}

  <div class="status-bar">
    <div class="status-item"><div class="status-dot" style="background:$wan_color"></div>wan-failover: $wan_status</div>
    <div class="status-item"><div class="status-dot" style="background:$samba_color"></div>smbd: $samba_status</div>
    <div class="status-item"><div class="status-dot" style="background:$dhcp_color"></div>isc-dhcp: $dhcp_status</div>
    <div class="status-item"><div class="status-dot" style="background:$ufw_color"></div>ufw: $ufw_status</div>
  </div>

  <div class="iface-pills">$wan_ifaces</div>

  <div class="modules">
    <a href="http://$HOST_IP:8081" class="module" style="--module-color:#00e5ff">
      <span class="module-port">:8081</span><span class="module-icon">⬡</span>
      <div class="module-title">DHCP</div>
      <div class="module-desc">WAN Failover, Static Routes, DHCP Reservations, DNS</div>
      <div class="module-tags"><span class="tag">WAN</span><span class="tag">Routing</span><span class="tag">DNS</span></div>
    </a>
    <a href="http://$HOST_IP:8082" class="module" style="--module-color:#ff6b35">
      <span class="module-port">:8082</span><span class="module-icon">⬢</span>
      <div class="module-title">Samba</div>
      <div class="module-desc">Manage, add, edit and delete file shares</div>
      <div class="module-tags"><span class="tag">SMB</span><span class="tag">Shares</span><span class="tag">Files</span></div>
    </a>
    <a href="http://$HOST_IP:8083" class="module" style="--module-color:#00ff88">
      <span class="module-port">:8083</span><span class="module-icon">🛡️</span>
      <div class="module-title">UFW</div>
      <div class="module-desc">Firewall rules, policies, logging and diagnostics</div>
      <div class="module-tags"><span class="tag">Security</span><span class="tag">Firewall</span><span class="tag">Rules</span></div>
    </a>
  </div>

  <div class="footer">
    Auto-refresh every 30s &nbsp;·&nbsp; <span>$(date '+%Y-%m-%d %H:%M:%S')</span>
  </div>
</div>

<a href="/access" class="access-btn">🔒 Access Control</a>

</body>
</html>
HTML
}

# ─── Startup ──────────────────────────────────────────────────────────────────

if [[ "${1}" == "__handler__" ]]; then
    handle_request; exit 0
fi

load_access_conf
TRANSPORT=$(ensure_socat)
export TRANSPORT

LAN_IF=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
PORTAL_IP=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
[[ -z "$PORTAL_IP" ]] && PORTAL_IP=$(hostname -I | awk '{print $1}')

log "Starting 1002xOPERATOR Portal on port $PORT (transport: $TRANSPORT)"
log "Portal:  http://${PORTAL_IP}:${PORT}/"
log "Access:  http://${PORTAL_IP}:${PORT}/access"
log "Config:  $ACCESS_CONF"

if [[ "$TRANSPORT" == "socat" ]]; then
    exec socat TCP-LISTEN:${PORT},reuseaddr,fork \
        SYSTEM:"TRANSPORT=socat bash ${SCRIPT_PATH} __handler__"
else
    log "Access Control: DISABLED (socat unavailable)"
    FIFO=$(mktemp -u); mkfifo "$FIFO"
    trap "rm -f '$FIFO'" EXIT INT TERM
    while true; do
        TRANSPORT=nc handle_request < "$FIFO" | nc -q 1 -l -p "$PORT" > "$FIFO" 2>/dev/null || \
        TRANSPORT=nc handle_request < "$FIFO" | nc -l -p "$PORT"       > "$FIFO" 2>/dev/null || \
        TRANSPORT=nc handle_request < "$FIFO" | nc -l "$PORT"          > "$FIFO" 2>/dev/null
    done
fi
