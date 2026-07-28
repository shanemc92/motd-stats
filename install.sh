#!/bin/bash
# MOTD installer - run as the normal user (it calls sudo where needed), NOT via sudo itself.
set -e

echo "=== MOTD Installer ==="

# --- Docker ---
HAS_DOCKER=false
SHOW_DOCKER_IPS=false
DOCKER_SOCKET_PROXY=""
if command -v docker &>/dev/null; then
	echo "Docker detected - will show container status."
	HAS_DOCKER=true
	read -rp "Docker/bridge interfaces (docker*, br-*, veth*) can flood the LAN IP line - show them anyway? [y/N]: " ans </dev/tty
	[[ "$ans" =~ ^[Yy]$ ]] && SHOW_DOCKER_IPS=true
	read -rp "Using a docker-socket-proxy instead of the local socket? Its address (e.g. tcp://127.0.0.1:2375), or blank to skip: " DOCKER_SOCKET_PROXY </dev/tty
fi

# Reads below use /dev/tty so prompts still work when this script is
# piped in via `curl ... | bash` (stdin is otherwise consumed by the script itself).

# --- VPN ---
read -rp "VPN interface to monitor, e.g. wg0 (blank to skip): " VPN_IFACE </dev/tty

# --- ntfy on updates ---
read -rp "Send an ntfy notification after nightly apt updates? [y/N]: " ans </dev/tty
NTFY_URL=""
if [[ "$ans" =~ ^[Yy]$ ]]; then
	read -rp "Full ntfy URL (e.g. https://ntfy.sh/mytopic): " NTFY_URL </dev/tty
fi

# --- Domain for VPN-leak / WAN IP check ---
read -rp "Domain that resolves to this server's public IP, for a VPN-leak check (blank to skip): " MY_DOMAIN </dev/tty

echo
echo "Deploying..."

# Config file consumed by motd-stats.sh at runtime
sudo tee /etc/motd-stats.conf > /dev/null <<EOF
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
grep -qxF "motd" ~/.bashrc || echo "motd" >> ~/.bashrc

# RetroPie welcome message, if present and not already commented out
grep -q "^retropie_welcome" ~/.bashrc 2>/dev/null && \
	sed -i 's/^retropie_welcome/#retropie_welcome/' ~/.bashrc

# UFW status without sudo password (only if ufw is installed)
if command -v ufw &>/dev/null && [ ! -f /etc/sudoers.d/ufwstatus ]; then
	sudo tee /etc/sudoers.d/ufwstatus > /dev/null <<'EOF'
Cmnd_Alias      UFWSTATUS = /usr/sbin/ufw status
%ufwstatus      ALL=NOPASSWD: UFWSTATUS
EOF
	sudo chmod 440 /etc/sudoers.d/ufwstatus
	getent group ufwstatus > /dev/null || sudo groupadd -r ufwstatus
	sudo gpasswd --add "$(whoami)" ufwstatus
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

	if [ ! -f /etc/sudoers.d/fail2banstatus ]; then
		sudo tee /etc/sudoers.d/fail2banstatus > /dev/null <<'EOF'
Cmnd_Alias      F2BSTATUS = /usr/local/sbin/f2b-status.sh
%f2banstatus    ALL=NOPASSWD: F2BSTATUS
EOF
		sudo chmod 440 /etc/sudoers.d/fail2banstatus
		getent group f2banstatus > /dev/null || sudo groupadd -r f2banstatus
		sudo gpasswd --add "$(whoami)" f2banstatus
	fi
fi

# Update alias (+ optional ntfy notify)
if [ -n "$NTFY_URL" ]; then
	UPDATE_CMD="alias update=\"sudo apt update && sudo apt upgrade -y && curl $NTFY_URL -H 'ta: ballot_box_with_check' -H 't: APT Updates' -d '$(hostname) Update Completed'\""
else
	UPDATE_CMD="alias update=\"sudo apt update && sudo apt upgrade -y\""
fi
grep -qF "alias update=" ~/.bash_aliases || echo "$UPDATE_CMD" >> ~/.bash_aliases

# Nightly cron apt update (idempotent)
grep -q "apt update" /etc/crontab || \
	echo -e "00 20\t* * *\troot\tapt update" | sudo tee -a /etc/crontab > /dev/null

echo
echo "Done. Log out and back in for group membership changes to take effect"
echo "(needed for UFW and fail2ban stats); 'source ~/.bashrc' is enough for everything else."
