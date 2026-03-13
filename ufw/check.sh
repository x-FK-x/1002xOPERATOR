#!/bin/bash

# UFW Firewall Manager - Status and Diagnostic Check
# Similar to DHCP's check functionality

UFW_CONFIG="/etc/1002xOPERATOR/ufw/settings"
RULES_FILE="$UFW_CONFIG/ufw-rules.conf"
LOGFILE="$UFW_CONFIG/ufw-actions.log"

mkdir -p "$UFW_CONFIG"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

echo "=== UFW Firewall Diagnostic Check ===" 
echo "Started: $(date)"
echo ""

# 1. Check if UFW is installed
if ! command -v ufw &>/dev/null; then
    whiptail --msgbox "[ERROR] UFW is not installed!\n\nInstall with:\nsudo apt install ufw" 10 60
    exit 1
fi

# 2. Check UFW status
UFW_STATUS=$(sudo ufw status 2>&1)
echo "UFW Status:"
echo "$UFW_STATUS"
echo ""

# 3. Count active rules
if sudo ufw status | grep -q "Status: active"; then
    RULE_COUNT=$(sudo ufw status numbered 2>/dev/null | grep -c "^\[" || echo "0")
    echo "Active Rules: $RULE_COUNT"
else
    echo "WARNING: UFW is not active!"
fi
echo ""

# 4. Show custom rules
if [[ -f "$RULES_FILE" && -s "$RULES_FILE" ]]; then
    CUSTOM_RULES=$(wc -l < "$RULES_FILE")
    echo "Custom Rules in Config: $CUSTOM_RULES"
    cat "$RULES_FILE"
else
    echo "Custom Rules in Config: None"
fi
echo ""

# 5. Check logging
UFW_LOG="/var/log/ufw.log"
if [[ -f "$UFW_LOG" ]]; then
    LOG_SIZE=$(du -h "$UFW_LOG" | awk '{print $1}')
    LOG_ENTRIES=$(wc -l < "$UFW_LOG")
    echo "UFW Log: $UFW_LOG ($LOG_SIZE, $LOG_ENTRIES lines)"
else
    echo "UFW Log: Not yet created"
fi
echo ""

# 6. Check recent blocked connections
echo "=== Recent Blocked Connections (if logging enabled) ==="
sudo tail -n 10 "$UFW_LOG" 2>/dev/null || echo "No log entries found"
echo ""

# 7. Show listening ports
echo "=== Listening Ports ==="
sudo netstat -tulpn 2>/dev/null | grep "LISTEN" || echo "netstat not available, trying ss..."
ss -tulpn 2>/dev/null | grep "LISTEN" || echo "No listening ports found"
echo ""

# 8. Check iptables rules
echo "=== IPv4 iptables Rules Count ==="
sudo iptables -L -n 2>/dev/null | grep -c "Chain" || echo "Unable to read iptables"
echo ""

# 9. Show action log
if [[ -f "$LOGFILE" && -s "$LOGFILE" ]]; then
    echo "=== Recent Actions (last 10) ==="
    tail -n 10 "$LOGFILE"
else
    echo "No action log entries yet"
fi
echo ""

# Display in whiptail
{
    echo "UFW Firewall Diagnostic Report"
    echo "==============================="
    echo ""
    echo "Status: $(sudo ufw status 2>&1 | head -1)"
    echo ""
    echo "Active Rules: $RULE_COUNT"
    echo "Custom Rules: $(test -f "$RULES_FILE" && wc -l < "$RULES_FILE" || echo "0")"
    echo ""
    echo "UFW Log: $UFW_LOG"
    echo ""
    echo "For detailed information, run:"
    echo "  sudo ufw status verbose"
    echo "  sudo ufw status numbered"
    echo "  sudo tail -f /var/log/ufw.log"
} | whiptail --title "UFW Firewall Diagnostic" --scrolltext --msgbox "$(cat)" 25 80

echo "=== Diagnostic completed: $(date) ==="
