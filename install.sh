#!/bin/bash
# MOTD installer - run as the normal user (it calls sudo where needed), NOT via sudo itself.
set -e

echo "=== MOTD Installer ==="

# Grants passwordless sudo for one command to one (auto-created) group, and
# adds the current user to it. Used for both UFW and fail2ban status checks.
setup_nopasswd_group() {
	local group="$1" alias_name="$2" cmd_path="$3"
	sudo tee "/etc/sudoers.d/$group" > /dev/null <<EOF
Cmnd_Alias      $alias_name = $cmd_path
%$group    ALL=NOPASSWD: $alias_name
EOF
	sudo chmod 440 "/etc/sudoers.d/$group"
	getent group "$group" > /dev/null || sudo groupadd -r "$group"
	sudo gpasswd --add "$(whoami)" "$group" > /dev/null
}

# Reads below use /dev/tty so prompts still work when this script is
# piped in via `curl ... | bash` (stdin is otherwise consumed by the script itself).

# --- Colour theme for separators/bullets/colons ---
THEME_NAMES=(Magenta Cyan Blue Green Yellow Red White)
THEME_CODES=(MAG CYA BLU GRE YEL RED WHI)
THEME_BRIGHT_TPUT=(13 14 12 10 11 9 15)
THEME_STD_TPUT=(5 6 4 2 3 1 7)
RST_T="$(tput sgr0)"
BW_T="$(tput bold)$(tput setaf 7)"
W_T="$(tput setaf 7)"
echo "Pick a colour theme for the MOTD (lines use the bright shade, bullets/colons the standard shade):"
for i in "${!THEME_NAMES[@]}"; do
	cb="$(tput setaf "${THEME_BRIGHT_TPUT[$i]}")"
	cs="$(tput setaf "${THEME_STD_TPUT[$i]}")"
	label="$(printf "%d) %-8s" "$((i+1))" "${THEME_NAMES[$i]}")"
	echo -e "${label} ${cb}●${RST_T}  ${cb}──────── ${cs}- ${BW_T}Example${cs} :${W_T} Value${RST_T}"
done
read -rp "Choice [1-7, default 1]: " theme_choice </dev/tty
theme_choice="${theme_choice:-1}"
THEME_COLOR="${THEME_CODES[$((theme_choice-1))]:-MAG}"

# --- Docker ---
SHOW_DOCKER_IPS=false
DOCKER_SOCKET_PROXY=""
if command -v docker &>/dev/null; then
	echo "Docker detected - will show container status."
	read -rp "Docker/bridge interfaces (docker*, br-*, veth*) can flood the LAN IP line - show them anyway? [y/N]: " ans </dev/tty
	[[ "$ans" =~ ^[Yy]$ ]] && SHOW_DOCKER_IPS=true
	read -rp "Using a docker-socket-proxy instead of the local socket? Its address (e.g. tcp://127.0.0.1:2375), or blank to skip: " DOCKER_SOCKET_PROXY </dev/tty
fi

# --- VPN ---
read -rp "VPN interface to monitor, e.g. wg0 (blank to skip): " VPN_IFACE </dev/tty

# --- Domain for VPN-leak / WAN IP check ---
read -rp "Domain that resolves to this server's public IP, for a VPN-leak check (blank to skip): " MY_DOMAIN </dev/tty

echo
echo "Deploying..."

# Config file consumed by motd-stats.sh at runtime
sudo tee /etc/motd-stats.conf > /dev/null <<EOF
THEME_COLOR="$THEME_COLOR"
VPN_IFACE="$VPN_IFACE"
MY_DOMAIN="$MY_DOMAIN"
SHOW_DOCKER_IPS=$SHOW_DOCKER_IPS
DOCKER_SOCKET_PROXY="$DOCKER_SOCKET_PROXY"
EOF

# Deploy the script - use a local copy if run from a cloned repo,
# otherwise fetch it (set MOTD_STATS_URL to your hosted raw file).
sudo mkdir -p /usr/bin/scripts
LOCAL_COPY="$(dirname "$0")/motd-stats.sh"
if [ -f "$LOCAL_COPY" ]; then
	sudo cp "$LOCAL_COPY" /usr/bin/scripts/motd-stats.sh
elif [ -n "$MOTD_STATS_URL" ]; then
	sudo curl -sL "$MOTD_STATS_URL" -o /usr/bin/scripts/motd-stats.sh
else
	echo "No local motd-stats.sh found and MOTD_STATS_URL not set. Aborting." >&2
	exit 1
fi
sudo chown root:root /usr/bin/scripts/motd-stats.sh
sudo chmod 755 /usr/bin/scripts/motd-stats.sh

# Remove default motd / last-login noise (back up originals first so uninstall.sh can restore them)
if [ -f /etc/motd ] && [ ! -f /etc/motd.motd-stats.bak ]; then
	sudo cp /etc/motd /etc/motd.motd-stats.bak
fi
sudo rm -f /etc/motd

if [ ! -f /etc/ssh/sshd_config.motd-stats.bak ]; then
	sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.motd-stats.bak
fi
if grep -qE '^#?[[:space:]]*PrintLastLog' /etc/ssh/sshd_config; then
	sudo sed -i -E 's/^#?[[:space:]]*PrintLastLog[[:space:]]+.*/PrintLastLog no/' /etc/ssh/sshd_config
else
	echo 'PrintLastLog no' | sudo tee -a /etc/ssh/sshd_config > /dev/null
fi
sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh 2>/dev/null
[ -f /etc/update-motd.d/10-uname ] && sudo sed -i 's/^uname -snrvm/#uname -snrvm/' /etc/update-motd.d/10-uname

# bash_aliases + bashrc (idempotent)
touch ~/.bash_aliases
grep -qxF "alias motd='/usr/bin/scripts/motd-stats.sh'" ~/.bash_aliases || \
	echo "alias motd='/usr/bin/scripts/motd-stats.sh'" >> ~/.bash_aliases
sed -i '/^alias update=/d' ~/.bash_aliases
echo 'alias update="sudo apt update && sudo apt upgrade -y"' >> ~/.bash_aliases
grep -qxF "motd" ~/.bashrc || echo "motd" >> ~/.bashrc

# RetroPie welcome message, if present and not already commented out
grep -q "^retropie_welcome" ~/.bashrc 2>/dev/null && \
	sed -i 's/^retropie_welcome/#retropie_welcome/' ~/.bashrc

# UFW status without sudo password (only if ufw is installed)
if command -v ufw &>/dev/null && [ ! -f /etc/sudoers.d/ufwstatus ]; then
	setup_nopasswd_group ufwstatus UFWSTATUS "/usr/sbin/ufw status"
fi

# fail2ban status without sudo password (only if fail2ban-client is installed).
# Wildcards aren't allowed in sudoers command args on newer sudo builds, so use
# a small wrapper script instead and grant that exact path with no arguments.
if command -v fail2ban-client &>/dev/null; then
	sudo tee /usr/local/sbin/f2b-status.sh > /dev/null <<'EOF'
#!/bin/bash
fail2ban-client status
for j in $(fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
	fail2ban-client status "$j"
done
EOF
	sudo chown root:root /usr/local/sbin/f2b-status.sh
	sudo chmod 755 /usr/local/sbin/f2b-status.sh

	[ -f /etc/sudoers.d/fail2banstatus ] || \
		setup_nopasswd_group f2banstatus F2BSTATUS "/usr/local/sbin/f2b-status.sh"
fi

# Nightly cron apt update - install cron first if it's missing
# (Ubuntu minimal cloud images don't ship it by default)
if ! command -v crontab &>/dev/null; then
	sudo apt-get update -qq
	sudo apt-get install -y cron
	sudo systemctl enable --now cron
fi
sudo touch /etc/crontab
grep -q "apt update" /etc/crontab || \
	echo -e "00 20\t* * *\troot\tapt update" | sudo tee -a /etc/crontab > /dev/null

echo
echo "Done. Log out and back in for group membership changes to take effect"
echo "(needed for UFW and fail2ban stats); 'source ~/.bashrc' is enough for everything else."
