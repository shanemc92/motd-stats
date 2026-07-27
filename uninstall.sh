#!/bin/bash
# Reverts changes made by install.sh. Run as the same user that ran install.sh
# (it calls sudo where needed, same as install.sh).

echo "=== MOTD Uninstaller ==="

# Deployed script + config
sudo rm -f /usr/bin/scripts/motd-stats.sh
sudo rm -f /etc/motd-stats.conf
sudo rm -f /usr/local/sbin/f2b-status.sh

# sudoers + groups
sudo rm -f /etc/sudoers.d/ufwstatus
sudo rm -f /etc/sudoers.d/fail2banstatus
sudo gpasswd --delete "$(whoami)" ufwstatus 2>/dev/null
sudo gpasswd --delete "$(whoami)" f2banstatus 2>/dev/null
sudo groupdel ufwstatus 2>/dev/null
sudo groupdel f2banstatus 2>/dev/null

# bash_aliases / bashrc
[ -f ~/.bash_aliases ] && sed -i '/^alias motd=/d; /^alias update=/d' ~/.bash_aliases
[ -f ~/.bashrc ] && sed -i '/^motd$/d' ~/.bashrc

# RetroPie welcome message, if install.sh commented it out
[ -f ~/.bashrc ] && sed -i 's/^#retropie_welcome/retropie_welcome/' ~/.bashrc

# update-motd.d uname line
[ -f /etc/update-motd.d/10-uname ] && sudo sed -i 's/^#uname -snrvm/uname -snrvm/' /etc/update-motd.d/10-uname

# sshd_config - restore from backup if install.sh made one
if [ -f /etc/ssh/sshd_config.motd-stats.bak ]; then
	sudo cp /etc/ssh/sshd_config.motd-stats.bak /etc/ssh/sshd_config
	sudo rm -f /etc/ssh/sshd_config.motd-stats.bak
	sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh 2>/dev/null
	echo "Restored /etc/ssh/sshd_config from backup."
else
	echo "No sshd_config backup found - PrintLastLog line left as-is, check manually if needed."
fi

# Default motd - restore backup if install.sh made one, otherwise leave it absent (system default)
if [ -f /etc/motd.motd-stats.bak ]; then
	sudo cp /etc/motd.motd-stats.bak /etc/motd
	sudo rm -f /etc/motd.motd-stats.bak
	echo "Restored /etc/motd from backup."
fi

# Nightly cron apt update entry
sudo sed -i '/00 20.*\* \* \*.*root.*apt update/d' /etc/crontab 2>/dev/null

echo
echo "Done. Open a new shell (or 'source ~/.bashrc') for changes to take effect."
