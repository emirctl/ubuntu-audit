#!/bin/bash

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# put sns topic arn here
SNS_TOPIC_ARN=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # no color


TIMESTAMP=$(date +"%Y%m%d_%H%M")
REPORT_FILE="ubuntu-audit-report-$TIMESTAMP.txt"
OS_NAME=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
HOSTNAME=$(hostname)


log_info() {
    echo -e "\n--- $1" >> "$REPORT_FILE"
}


check() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    
    if [ "$status" == "PASS" ]; then
        echo -e "[PASS] $test_name: $message" >> "$REPORT_FILE"
        echo -e "[${GREEN}PASS${NC}] $test_name: $message"
    elif [ "$status" == "SKIP" ]; then
        echo -e "[SKIP] $test_name: $message" >> "$REPORT_FILE"
        echo -e "[${YELLOW}SKIP${NC}] $test_name: $message"
    else
        echo -e "[FAIL] $test_name: $message" >> "$REPORT_FILE"
        echo -e "[${RED}FAIL${NC}] $test_name: $message"
    fi
}

echo "Ubuntu Audit Tool" >> "$REPORT_FILE"
echo "OS: $OS_NAME" >> "$REPORT_FILE"
echo "Hostname: $HOSTNAME" >> "$REPORT_FILE"
echo "Date: $(date)" >> "$REPORT_FILE"
echo "Running Audit... Please wait."


# check auto updates
if systemctl is-active --quiet unattended-upgrades; then
    check "Auto Updates" "PASS" "Service is active and running"
else
    check "Auto Updates" "FAIL" "Service is not running"
fi


# check ssh configuration
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    grep -E "^[[:space:]]*PermitRootLogin[[:space:]]+no" "$SSHD_CONFIG" -q && check "SSH Root Login" "PASS" "Disabled" || check "SSH Root Login" "FAIL" "Enabled"
    grep -E "^[[:space:]]*PasswordAuthentication[[:space:]]+no" "$SSHD_CONFIG" -q && check "SSH Password Auth" "PASS" "Disabled" || check "SSH Password Auth" "FAIL" "Enabled"
else
    check "SSH Config" "FAIL" "Config file missing"
fi


# active sessions
USERS_LOGGED_IN=$(who | awk '{print $1}' | sort -u | xargs)
check "Logged-in Users" "PASS" "Current users: $USERS_LOGGED_IN"


# failed logins last 24 hors
FAILED_COUNT=$(journalctl _SYSTEMD_UNIT=ssh.service --since "24 hours ago" 2>/dev/null | grep -ic "failed password")
[ "$FAILED_COUNT" -lt 50 ] && check "SSH Failed Logins" "PASS" "$FAILED_COUNT failed attempts" || check "SSH Failed Logins" "FAIL" "High risk: $FAILED_ATTEMPTS attempts"


# inbound ports
OPEN_PORTS=$(ss -tulpn | grep "LISTEN" | grep -v "127.0.0.1" | awk '{print $5}' | cut -d':' -f2 | sort -u | tr '\n' ' ')
[ -n "$OPEN_PORTS" ] && check "Open Ports" "FAIL" "Listening on: $OPEN_PORTS" || check "Open Ports" "PASS" "No open ports"


# ufw firewall
if [[ $EUID -eq 0 ]]; then 
    ufw status | grep -qw "active" && check "UFW Status" "PASS" "Active" || check "UFW Status" "FAIL" "Inactive"
else
    check "UFW Status" "SKIP" "Run this script as sudo"
fi


echo -e "\nAudit Complete. Report generated: $REPORT_FILE"
echo "Sending full report via AWS SNS..."


FULL_REPORT=$(cat "$REPORT_FILE")

# get current region
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

[ -z "$AWS_REGION" ] && AWS_REGION="us-east-1"


# AWS SNS Publish with Timeout
timeout 10s aws sns publish \
    --topic-arn "$SNS_TOPIC_ARN" \
    --message "$FULL_REPORT" \
    --subject "Audit Report: $HOSTNAME" \
    --region $(curl -s --connect-timeout 2 "$AWS_REGION" || echo "us-east-1") > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "Success: Report sent to SNS."
else
    echo "Error: Failed to send report or timed out."
fi
