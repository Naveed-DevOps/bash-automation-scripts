#!/usr/bin/env bash
set -euo pipefail

# =========================
# ENV / SAFETY
# =========================
export PATH=/usr/bin:/bin
export LANG=C.UTF-8

LOCK_FILE="/var/tmp/docker_alert.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || exit 0

# =========================
# CONFIGURATION
# =========================
DOCKER_BIN="/usr/bin/docker"
MSMTP_BIN="/usr/bin/msmtp"
HOSTNAME_BIN="/usr/bin/hostname"

STATE_FILE="/var/tmp/docker_alert_state"
EMAIL_LOG="/home/naveed-ullah/smtp_email2.log"

COOLDOWN=900        # 15 minutes
LOG_LINES=60

RECIPIENT="naveedulah172@gmail.com"
SENDER="alerts@octalooptechnologies.com"

# =========================
# INIT
# =========================
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

HOSTNAME="$($HOSTNAME_BIN)"
NOW=$(date +%s)

# =========================
# FUNCTIONS
# =========================
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$EMAIL_LOG"
}

is_cooled_down() {
    local key="$1"
    local last=0

    if grep -q "^$key " "$STATE_FILE"; then
        last=$(grep "^$key " "$STATE_FILE" | awk '{print $2}')
    fi

    if (( NOW - last < COOLDOWN )); then
        return 1
    fi

    grep -v "^$key " "$STATE_FILE" > "${STATE_FILE}.tmp" || true
    echo "$key $NOW" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"

    return 0
}

send_email() {
    local subject="$1"
    local body="$2"
    local msg_id="<$(date +%s).$$@$HOSTNAME>"

    {
        echo "From: $SENDER"
        echo "To: $RECIPIENT"
        echo "Message-ID: $msg_id"
        echo "Subject: $subject"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        echo "$body"
    } | "$MSMTP_BIN" -a default "$RECIPIENT" >> "$EMAIL_LOG" 2>&1 \
      || log_msg "ERROR: msmtp failed"
}

# =========================
# DOCKER EXITED CONTAINERS
# =========================
"$DOCKER_BIN" ps -a --filter status=exited --format '{{.ID}} {{.Names}}' | while read -r cid cname; do

    exit_code=$("$DOCKER_BIN" inspect --format='{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 0)
    oom_killed=$("$DOCKER_BIN" inspect --format='{{.State.OOMKilled}}' "$cid" 2>/dev/null || echo false)

    # Ignore normal/manual stops
    if [[ "$exit_code" -eq 0 || "$exit_code" -eq 143 ]] && [[ "$oom_killed" == "false" ]]; then
        continue
    fi

    key="docker_exit_$cid"

    if is_cooled_down "$key"; then
        logs=$("$DOCKER_BIN" logs --tail "$LOG_LINES" "$cid" 2>&1 || echo "Logs unavailable")

        body=$(cat <<EOF
Hostname : $HOSTNAME
Timestamp: $(date '+%a %b %d %I:%M:%S %p %Z %Y')
Alert    : Docker container exited

Container Name: $cname
Container ID  : $cid

Last $LOG_LINES log lines:
$logs
EOF
)
        send_email "Alert: Docker container exited ($cname)" "$body"
    fi
done

log_msg "Script execution completed"
