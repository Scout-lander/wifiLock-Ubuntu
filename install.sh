#!/usr/bin/env bash
set -euo pipefail

# =======================
# Helpers
# =======================
cecho() { printf "%b\n" "$1"; }

# When piped (curl | bash), reads from stdin don't have a TTY.
# Force interactive prompts to read from the terminal.
TTY_INPUT="/dev/tty"

ask_ynu() {
  local prompt="$1" ans
  while true; do
    if read -rp "$prompt [Y/N/U]: " ans < "$TTY_INPUT"; then
      :
    else
      ans=""
    fi
    ans="$(echo "${ans}" | tr '[:lower:]' '[:upper:]')"
    case "$ans" in
      Y|N|U) echo "$ans"; return 0 ;;
      *) echo "Please enter Y, N, or U." ;;
    esac
  done
}

ask_yesno() {
  local prompt="$1" def="${2:-Y}" ans
  local show="Y/n"; [[ "${def^^}" == "N" ]] && show="y/N"
  while true; do
    if read -rp "$prompt [$show]: " ans < "$TTY_INPUT"; then
      :
    else
      ans="$def"
    fi
    ans="${ans:-$def}"
    ans="$(echo "$ans" | tr '[:lower:]' '[:upper:]')"
    case "$ans" in Y|N) echo "$ans"; return 0 ;; esac
    echo "Please enter Y or N."
  done
}

ask_input() {
  local prompt="$1" def="${2:-}" ans
  if read -rp "$prompt ${def:+($def)}: " ans < "$TTY_INPUT"; then
    :
  else
    ans="$def"
  fi
  echo "${ans:-$def}"
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo bash install.sh"
    exit 1
  fi
}

detect_os() { . /etc/os-release; echo "${ID:-ubuntu}"; }

current_login_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
  else
    who am i 2>/dev/null | awk '{print $1}' || whoami
  fi
}

current_ssid_quick() {
  nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
}

wait_for_ssid() {
  local timeout="${1:-15}"
  local ssid=""
  local t=0
  local frames='|/-\'
  local i=0

  printf "Checking Wi-Fi for current SSID (up to %ss) " "$timeout" >&2
  while (( t < timeout )); do
    ssid="$(current_ssid_quick || true)"
    if [[ -n "$ssid" ]]; then
      printf "\rDetected SSID: %s%*s\n" "$ssid" 20 "" >&2
      echo "$ssid"
      return 0
    fi
    printf "\rChecking Wi-Fi %s " "${frames:i++%${#frames}:1}" >&2
    sleep 0.2
    ((t+=1))
  done
  printf "\rNo Wi-Fi SSID detected.%*s\n" 40 "" >&2
  echo ""
  return 1
}

# =======================
# Non-interactive flags (optional)
# =======================
USER_NAME_DEFAULT="$(current_login_user)"
ACTION=""
PURGE="0"
USER_NAME="$USER_NAME_DEFAULT"
SSIDS=""
DEBOUNCE="7"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --ssids) SSIDS="$2"; shift 2 ;;
    --debounce) DEBOUNCE="$2"; shift 2 ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --install) ACTION="install"; shift ;;
    --purge) PURGE="1"; shift ;;
    -h|--help)
      cat <<EOF
Usage: sudo bash install.sh [--install|--uninstall] [--purge] [--user <name>] [--ssids "ssid1,ssid2"] [--debounce <seconds>]
If no flags are provided, an interactive wizard will prompt you.

Examples:
  Install interactively:
    sudo bash install.sh
  Install non-interactively:
    sudo bash install.sh --install --user cam --ssids "HomeWiFi,OfficeWiFi" --debounce 7
  Uninstall (keep /etc/trusted-ssids.conf):
    sudo bash install.sh --uninstall
  Uninstall and remove everything (purge):
    sudo bash install.sh --uninstall --purge
EOF
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

need_root
OS_ID="$(detect_os)"

# =======================
# Interactive wizard (if no ACTION)
# =======================
if [[ -z "$ACTION" ]]; then
  cecho "Wi-Fi-aware Login/Lock installer"
  cecho "--------------------------------"

  ans="$(ask_ynu "Proceed? Y to install | N to cancel | U to uninstall")"
  case "$ans" in
    N) echo "Canceled."; exit 0 ;;
    U) ACTION="uninstall" ;;
    Y) ACTION="install" ;;
  esac
fi

# =======================
# Paths
# =======================
CONF_TRUST="/etc/trusted-ssids.conf"
LOG_LOCK="/var/log/ssid-lock-guard.log"
LOG_TOGGLE="/var/log/conditional-gdm.log"
BIN_USR_LOCAL="/usr/local/bin"
SBIN_USR_LOCAL="/usr/local/sbin"
NM_DISPATCHER="/etc/NetworkManager/dispatcher.d/90-ssid-lock-guard"
GDM_CONF="/etc/gdm3/custom.conf"
SERVICE="/etc/systemd/system/conditional-gdm-autologin.service"
TOGGLE="$SBIN_USR_LOCAL/toggle-gdm-autologin.sh"
LOCK_GUARD="$BIN_USR_LOCAL/ssid-lock-guard.sh"
TRUST_HELPER="$BIN_USR_LOCAL/trustssid"
LIST_HELPER="$BIN_USR_LOCAL/listtrusted"
UNTRUST_HELPER="$BIN_USR_LOCAL/untrustssid"

# =======================
# Uninstall
# =======================
if [[ "$ACTION" == "uninstall" ]]; then
  echo "Uninstalling…"
  systemctl disable --now NetworkManager-dispatcher.service >/dev/null 2>&1 || true
  rm -f "$NM_DISPATCHER" || true

  systemctl disable conditional-gdm-autologin.service >/dev/null 2>&1 || true
  rm -f "$SERVICE" || true

  rm -f "$TOGGLE" "$LOCK_GUARD" "$TRUST_HELPER" "$LIST_HELPER" "$UNTRUST_HELPER" || true
  rm -f "$LOG_LOCK" "$LOG_TOGGLE" || true

  if [[ "$PURGE" == "1" ]]; then
    rm -f "$CONF_TRUST" || true
  fi

  systemctl daemon-reload || true
  echo "Uninstalled. You may edit/remove $GDM_CONF manually if desired."
  exit 0
fi

# =======================
# Interactive details
# =======================
if [[ -z "${SSIDS}" ]]; then
  # User selection
  cur_user="$(current_login_user)"
  yn_add_self="$(ask_yesno "Add current user '$cur_user'?" "Y")"
  if [[ "$yn_add_self" == "Y" ]]; then
    USER_NAME="$cur_user"
  else
    USER_NAME="$(ask_input "Enter username to use for auto-login" "$USER_NAME_DEFAULT")"
  fi

  # Optional additional user (rare; can be blank)
  yn_add_other="$(ask_yesno "Add another user (override user above)?" "N")"
  if [[ "$yn_add_other" == "Y" ]]; then
    USER_NAME="$(ask_input "Enter username to use for auto-login" "$USER_NAME")"
  fi

  # SSIDs
  cur_ssid="$(wait_for_ssid 15 || true)"
  SSID_LIST=()

  if [[ -n "$cur_ssid" ]]; then
    yn_cur_ssid="$(ask_yesno "Add current SSID '$cur_ssid' as trusted?" "Y")"
    [[ "$yn_cur_ssid" == "Y" ]] && SSID_LIST+=("$cur_ssid")
  else
    echo "Skipping current SSID step (none detected)."
  fi

  while true; do
    yn_more="$(ask_yesno "Add another SSID?" "N")"
    [[ "$yn_more" == "N" ]] && break
    extra="$(ask_input "Enter SSID (case-sensitive)")"
    [[ -n "$extra" ]] && SSID_LIST+=("$extra")
  done

  # Debounce
  DEBOUNCE="$(ask_input "Debounce seconds (wait before locking on disconnect)" "7")"

  # Build CSV
  if [[ ${#SSID_LIST[@]} -gt 0 ]]; then
    SSIDS="$(printf "%s," "${SSID_LIST[@]}")"
    SSIDS="${SSIDS%,}"
  else
    SSIDS=""
  fi
fi

# =======================
# Install deps
# =======================
echo "Installing dependencies…"
case "$OS_ID" in
  ubuntu|debian)
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y crudini network-manager
    ;;
  *)
    echo "Unsupported distro ($OS_ID). Install 'crudini' and 'network-manager' then re-run."
    exit 1 ;;
esac

# =======================
# Write trusted SSIDs config
# =======================
echo "Writing trusted SSIDs to $CONF_TRUST"
{
  echo "# One SSID per line (case-sensitive). Lines starting with # are comments."
  if [[ -n "$SSIDS" ]]; then
    IFS=',' read -r -a arr <<< "$SSIDS"
    for s in "${arr[@]}"; do
      s_trim="$(echo "$s" | sed 's/^ *//; s/ *$//')"
      [[ -n "$s_trim" ]] && echo "$s_trim"
    done
  fi
} > "$CONF_TRUST"
chmod 644 "$CONF_TRUST"

# =======================
# Toggle script (pre-GDM)
# =======================
echo "Installing toggle script…"
cat > "$TOGGLE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/conditional-gdm.log
exec >>"$LOG" 2>&1
echo "---- $(date) start ----"

USER_NAME="__USER_NAME__"
GDM_CONF="/etc/gdm3/custom.conf"
CONF="/etc/trusted-ssids.conf"

# Load trusted SSIDs
mapfile -t TRUSTED_SSIDS < <(sed -e 's/#.*//' -e '/^\s*$/d' "$CONF" 2>/dev/null || true)

touch "$GDM_CONF"
crudini --set "$GDM_CONF" daemon AutomaticLogin "$USER_NAME" || true
crudini --set "$GDM_CONF" daemon AutomaticLoginEnable false   || true

CURRENT_SSID=""
for i in {1..30}; do
  CURRENT_SSID="$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2; exit}')"
  [[ -n "$CURRENT_SSID" ]] && break
  sleep 1
done
echo "SSID='${CURRENT_SSID:-<none>}'"

IS_TRUSTED=false
for ssid in "${TRUSTED_SSIDS[@]}"; do
  if [[ "${CURRENT_SSID:-}" == "$ssid" ]]; then IS_TRUSTED=true; break; fi
done
echo "trusted=$IS_TRUSTED"

if [[ "$IS_TRUSTED" == true ]]; then
  crudini --set "$GDM_CONF" daemon AutomaticLoginEnable true
  echo "Set auto-login: true"
else
  crudini --set "$GDM_CONF" daemon AutomaticLoginEnable false
  echo "Set auto-login: false"
fi

echo "---- $(date) end ----"
EOF
sed -i "s|__USER_NAME__|${USER_NAME}|g" "$TOGGLE"
chmod 755 "$TOGGLE"
touch "$LOG_TOGGLE" && chmod 644 "$LOG_TOGGLE"

# =======================
# Debounced lock guard
# =======================
echo "Installing lock guard…"
cat > "$LOCK_GUARD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/trusted-ssids.conf"
DEBOUNCE_SECONDS=__DEBOUNCE__
LOG=/var/log/ssid-lock-guard.log

# Load trusted SSIDs
mapfile -t TRUSTED_SSIDS < <(sed -e 's/#.*//' -e '/^\s*$/d' "$CONF" 2>/dev/null || true)

mkdir -p /run
exec 9>/run/ssid-lock-guard.lock
if ! flock -n 9; then exit 0; fi

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

get_ssid() {
  nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2; exit}'
}

is_trusted() {
  local s="$1"
  for ssid in "${TRUSTED_SSIDS[@]}"; do [[ "$s" == "$ssid" ]] && return 0; done
  return 1
}

SSID_NOW="$(get_ssid)"
log "Event: SSID_NOW='${SSID_NOW:-<none>}'"

if is_trusted "${SSID_NOW:-}"; then
  log "Trusted now -> no action"; exit 0
fi

log "Untrusted now -> waiting ${DEBOUNCE_SECONDS}s"
sleep "$DEBOUNCE_SECONDS"

SSID_AFTER="$(get_ssid)"
log "Recheck: SSID_AFTER='${SSID_AFTER:-<none>}'"

if is_trusted "${SSID_AFTER:-}"; then
  log "Trusted after wait -> no action"; exit 0
fi

log "Still untrusted -> locking sessions"
loginctl lock-sessions || true
if command -v gdbus >/dev/null 2>&1; then
  gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.SetActive true || true
fi
EOF
sed -i "s|__DEBOUNCE__|${DEBOUNCE}|g" "$LOCK_GUARD"
chmod 755 "$LOCK_GUARD"
touch "$LOG_LOCK" && chmod 644 "$LOG_LOCK"

# =======================
# Helper commands
# =======================
echo "Installing helper commands…"

cat > "$TRUST_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/trusted-ssids.conf"

SSID="$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2; exit}')"
if [[ -z "${SSID:-}" ]]; then
  echo "Not connected to Wi-Fi. Connect first."; exit 1
fi

if grep -Fxq "$SSID" "$CONF" 2>/dev/null; then
  echo "'$SSID' already trusted."
else
  echo "$SSID" | sudo tee -a "$CONF" >/dev/null
  echo "Added '$SSID' to $CONF"
fi
EOF
chmod 755 "$TRUST_HELPER"

cat > "$LIST_HELPER" <<'EOF'
#!/usr/bin/env bash
CONF="/etc/trusted-ssids.conf"
echo "Trusted SSIDs:"
grep -v '^\s*#' "$CONF" 2>/dev/null | sed '/^\s*$/d' || echo "(none)"
EOF
chmod 755 "$LIST_HELPER"

cat > "$UNTRUST_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/trusted-ssids.conf"
if [[ $# -lt 1 ]]; then
  echo "Usage: untrustssid \"SSID name\""; exit 1
fi
TMP="$(mktemp)"
grep -Fxv "$1" "$CONF" 2>/dev/null > "$TMP" || true
sudo mv "$TMP" "$CONF"
sudo chmod 644 "$CONF"
echo "Removed '$1' from $CONF (if it was present)."
EOF
chmod 755 "$UNTRUST_HELPER"

# =======================
# NM dispatcher hook
# =======================
echo "Installing NetworkManager dispatcher hook…"
cat > "$NM_DISPATCHER" <<'EOF'
#!/usr/bin/env bash
# Run guard on any NM event (debounce handled in the script)
 /usr/local/bin/ssid-lock-guard.sh
EOF
chmod 755 "$NM_DISPATCHER"
systemctl enable --now NetworkManager-dispatcher.service >/dev/null 2>&1 || true

# =======================
# Clean GDM config (default disabled)
# =======================
echo "Writing GDM config at $GDM_CONF"
cat > "$GDM_CONF" <<EOF
[daemon]
AutomaticLoginEnable=false
AutomaticLogin=${USER_NAME}
EOF

# =======================
# Systemd unit (pre-GDM)
# =======================
echo "Installing systemd service…"
cat > "$SERVICE" <<'EOF'
[Unit]
Description=Toggle GDM auto-login based on trusted Wi-Fi
Wants=NetworkManager-wait-online.service
After=network-online.target NetworkManager.service NetworkManager-wait-online.service
Before=gdm3.service gdm.service display-manager.service
ConditionPathExists=/usr/local/sbin/toggle-gdm-autologin.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/toggle-gdm-autologin.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable conditional-gdm-autologin.service >/dev/null 2>&1 || true

# Make known SSIDs system-wide so greeter can connect
if [[ -n "$SSIDS" ]]; then
  IFS=',' read -r -a arr2 <<< "$SSIDS"
  for s in "${arr2[@]}"; do
    s_trim="$(echo "$s" | sed 's/^ *//; s/ *$//')"
    if nmcli -t connection show | cut -d: -f1 | grep -Fxq "$s_trim"; then
      nmcli connection modify "$s_trim" connection.permissions "" connection.autoconnect yes || true
    fi
  done
fi
nmcli radio wifi on || true

echo
echo "Done ✔"
echo "User:          $USER_NAME"
echo "Trusted SSIDs: ${SSIDS:-'(none added here; use trustssid)'}"
echo "Debounce:      ${DEBOUNCE}s"
echo
echo "Commands: trustssid, listtrusted, untrustssid"
echo "Reboot to test auto-login on trusted SSID."
