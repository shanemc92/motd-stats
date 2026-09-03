#!/bin/bash

# Load per-host config if present (written by install.sh)
[ -f /etc/motd-stats.conf ] && source /etc/motd-stats.conf

# Colours
RST="$(tput sgr0)"
BLD="${RST}$(tput bold)"
BLK="${RST}$(tput setaf 0)"
RED="${RST}$(tput setaf 9)"
GRE="${RST}$(tput setaf 10)"
YEL="${RST}$(tput setaf 11)"
BLU="${RST}$(tput setaf 12)"
MAG="${RST}$(tput setaf 13)"
CYA="${RST}$(tput setaf 14)"
WHI="${RST}$(tput setaf 15)"
BBLK="${BLD}$(tput setaf 0)"
BRED="${BLD}$(tput setaf 9)"
BGRE="${BLD}$(tput setaf 10)"
BYEL="${BLD}$(tput setaf 11)"
BBLU="${BLD}$(tput setaf 12)"
BMAG="${BLD}$(tput setaf 13)"
BCYA="${BLD}$(tput setaf 14)"
BWHI="${BLD}$(tput setaf 15)"
DGRY="${RST}\e[90m"
ORA="${RST}\e[38;5;202m"

# Separator/bullet colour theme, set by install.sh (defaults to magenta)
case "$THEME_COLOR" in
	CYA) THEME_CLR="$CYA" ;;
	BLU) THEME_CLR="$BLU" ;;
	GRE) THEME_CLR="$GRE" ;;
	YEL) THEME_CLR="$YEL" ;;
	RED) THEME_CLR="$RED" ;;
	WHI) THEME_CLR="$WHI" ;;
	*)   THEME_CLR="$MAG" ;;
esac

LIN=" ${THEME_CLR}───────────────────────────────────────────────────────────────"
BUL=" ${THEME_CLR}- "
SEP=" ${THEME_CLR}:${WHI} "

CPU_TEMP(){
	local tf=/sys/class/thermal/thermal_zone0/temp
	[ -r "$tf" ] || return 1
	local temp="$(( $(<"$tf") / 1000 ))"
	if (( temp >= 70 )); then
		temp="\e[1;31mWARNING: $temp°C (Reducing the life of your device)\e[0m"
	elif (( temp >= 60 )); then
		temp="\e[38;5;202m$temp°C \e[90m(Running hot, not recommended)\e[0m"
	elif (( temp >= 50 )); then
		temp="\e[1;33m$temp°C \e[90m(Running warm, but safe)\e[0m"
	elif (( temp >= 40 )); then
		temp="\e[1;32m$temp°C \e[90m(Optimal temperature)\e[0m"
	elif (( temp >= 30 )); then
		temp="\e[1;36m$temp°C \e[90m(Cool runnings)\e[0m"
	else
		temp="\e[1;36m$temp°C \e[90m(Who put me in the freezer!)\e[0m"
	fi
	echo -e "$temp"
}

print_header(){
	local os_name
	if [ -f /etc/os-release ]; then
		os_name=$(. /etc/os-release; echo "$PRETTY_NAME")
	else
		os_name="Debian $(cat /etc/debian_version)"
	fi
	local date=$(date +"%R - %a %d/%m/%y")
	echo -e "$LIN"
	echo -e "${BUL}${BYEL}$(hostname)$SEP${BWHI}${os_name}$SEP$date"
	echo -e "$LIN"
}

check_under_voltage(){
	command -v vcgencmd &>/dev/null || return
	local check="$(vcgencmd get_throttled)"
	[[ $check != 'throttled=0x0' ]] && echo -e "${BRED}Pi might be under voltage, check syslog 'sudo tail -100 /var/log/syslog'\n"
}

VAR_MODEL="$( [ -f /proc/device-tree/model ] && tr -d '\0' </proc/device-tree/model || echo "$(uname -m) ($(uname -o))" )"
VAR_UPTIME="$(uptime | sed -E 's/^[^,]*up *//; s/, *[[:digit:]]* user.*//; s/min/minutes/; s/([[:digit:]]+):0?([[:digit:]]+)/\1 hours, \2 minutes/')"

# LAN IP - excludes Docker/bridge interfaces (docker*, br-*, veth*) by default,
# since a Docker host can have dozens of these; set SHOW_DOCKER_IPS=true to include them
if [ "$SHOW_DOCKER_IPS" = "true" ]; then
	VAR_IP_INTERN="$(hostname -I)"
else
	VAR_IP_INTERN="$(ip -o -4 addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth)/ {print $4}' | cut -d/ -f1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
fi
VAR_IP_EXTERN="$(timeout --signal=SIGINT 3 wget -q -O - http://icanhazip.com/ | tail)"

# WAN IP / VPN-leak check - only if a domain was configured
if [ -n "$MY_DOMAIN" ]; then
	VAR_MY_IP="$(curl -s "https://dns.google/resolve?name=$MY_DOMAIN" | grep -oP '"data":"\K[^"]+')"
	if echo "${VAR_IP_EXTERN}" | grep -q "${VAR_MY_IP}"; then
		VAR_IP_VPN="${YEL}${VAR_IP_EXTERN} ${DGRY}(No VPN)"
	else
		VAR_IP_VPN="${GRE}${VAR_IP_EXTERN} ${DGRY}(VPN)"
	fi
else
	VAR_IP_VPN="${WHI}${VAR_IP_EXTERN}"
fi

VAR_TEMP="$(CPU_TEMP)"
VAR_LOADAVG="$(uptime | sed 's/^.*\(load*\)/\1/g' | awk '{printf "%s (1m) %s (5m) %s (15m)", substr($3,0,5),substr($4,0,5),substr($5,0,5); }')"
VAR_MEMORY="$(free -m | awk 'NR==2 { printf "Used: %sMB (%.0f%%), %sMB free of %sMB",$3,substr($3/$2*100,0,3),$4,$2; }')"
VAR_SWAP="$(free -m | awk 'NR==3 { if ($2>0) printf "Used: %sMB (%.0f%%), %sMB free of %sMB",$3,($3/$2*100),$4,$2; else printf "None configured" }')"
VAR_SPACE="$(df -h ~ | awk 'NR==2 { printf "Used: %sB (%.0f%%), %sB free of %sB",$3,substr($3/$2*100,0,3),$4,$2; }')"

# Failed systemd units - only if systemd present
if command -v systemctl &>/dev/null; then
	failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)"
	if [ "$failed_units" -eq 0 ]; then
		VAR_FAILED_UNITS="${GRE}0"
	else
		VAR_FAILED_UNITS="${RED}${failed_units} ${DGRY}(systemctl --failed)"
	fi
fi

# Reboot required - only shown when true
[ -f /var/run/reboot-required ] && VAR_REBOOT="${RED}YES"

# VPN interface - shown whenever configured; a missing interface counts as DOWN
# (wg-quick down removes it entirely, so absence and down are the same state).
# Note: point-to-point interfaces like WireGuard report "state UNKNOWN" even when
# up (no carrier-detection for a virtual p2p link), so check the flag list instead.
if [ -n "$VPN_IFACE" ]; then
	link_flags="$(ip -o link show "$VPN_IFACE" 2>/dev/null | grep -oP '(?<=<)[^>]+')"
	if echo ",${link_flags}," | grep -q ',UP,'; then
		VAR_VPN="${GRE}UP"
	else
		VAR_VPN="${RED}DOWN"
	fi
fi

# UFW - only if installed
if command -v ufw &>/dev/null; then
	if sudo ufw status | awk '{print $2}' | grep -q "inactive"; then
		VAR_UFW="${RED}DISABLED"
	else
		VAR_UFW="${GRE}ENABLED"
	fi
fi

# Docker - only if installed; falls back to a configured socket-proxy (DOCKER_SOCKET_PROXY)
# if the direct socket isn't reachable, and hides the line entirely if both fail
if command -v docker &>/dev/null; then
	docker_env=""
	if ! docker ps -q &>/dev/null; then
		if [ -n "$DOCKER_SOCKET_PROXY" ] && DOCKER_HOST="$DOCKER_SOCKET_PROXY" docker ps -q &>/dev/null; then
			docker_env="DOCKER_HOST=$DOCKER_SOCKET_PROXY"
		else
			docker_env=""
			docker_unavailable=true
		fi
	fi
	if [ -z "$docker_unavailable" ]; then
		VAR_DOCKER="$(env $docker_env docker ps -q | wc -l) running / $(env $docker_env docker ps -aq | wc -l) total"
	fi
fi

VAR_WEATHER="$(curl -sSfLm 2 https://wttr.in/?format=4 2>&1)"
VAR_AVAIL_UPDATES="$(( $(apt list --upgradable 2>/dev/null | wc -l) - 1 )) updates, $(apt list --upgradable 2>/dev/null | grep -ic security) Security"
VAR_LAST_LOGIN="$(last 2>/dev/null | awk 'NR==3 {print $4, $5, $6, $7, $1, "from", $3}')"

# fail2ban - failed-login log, only if it exists
if [ -f /etc/fail2ban/logs/failed_logins.log ]; then
	VAR_LAST_FAIL="$(awk '{ cmd = "date -d @"$1" +\"%a %b %d %H:%M\""; cmd | getline formatted_time; close(cmd); print formatted_time, $2, $3, $4 }' /etc/fail2ban/logs/failed_logins.log)"
fi

# fail2ban - currently banned IPs across all jails, only if the sudoers wrapper exists
if [ -x /usr/local/sbin/f2b-status.sh ]; then
	banned="$(sudo /usr/local/sbin/f2b-status.sh 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*//p' | awk '{s+=$1} END{print s+0}')"
	if [ "$banned" -eq 0 ]; then
		VAR_F2B_BANNED="${GRE}0"
	elif [ "$banned" -le 10 ]; then
		VAR_F2B_BANNED="${YEL}${banned} ${DGRY}(sudo fail2ban-client status <jail>)"
	elif [ "$banned" -le 20 ]; then
		VAR_F2B_BANNED="${ORA}${banned} ${DGRY}(sudo fail2ban-client status <jail>)"
	else
		VAR_F2B_BANNED="${RED}${banned} ${DGRY}(sudo fail2ban-client status <jail>)"
	fi
fi

# Last apt update - only if the log exists
if [ -f /var/log/apt/history.log ]; then
	VAR_LAST_APT="$(grep "Start-Date" /var/log/apt/history.log | tail -n1 | awk '{print $2, $3}')"
fi

G_TERM_CLEAR 2> /dev/null || printf "\ec"

print_header
echo -e "${BUL}${BWHI}Model${SEP}${WHI}${VAR_MODEL}"
echo -e "${BUL}${BWHI}Uptime${SEP}${WHI}${VAR_UPTIME}"
echo -e "${BUL}${BWHI}LAN IP${SEP}${WHI}${VAR_IP_INTERN}"
echo -e "${BUL}${BWHI}WAN IP${SEP}${WHI}${VAR_IP_VPN}"
[ -n "$VAR_TEMP" ] && echo -e "${BUL}${BWHI}CPU Temp${SEP}${WHI}${VAR_TEMP}"
echo -e "${BUL}${BWHI}CPU Load${SEP}${WHI}${VAR_LOADAVG}"
echo -e "${BUL}${BWHI}Memory${SEP}${WHI}${VAR_MEMORY}"
echo -e "${BUL}${BWHI}Swap${SEP}${WHI}${VAR_SWAP}"
echo -e "${BUL}${BWHI}Filesystem${SEP}${WHI}${VAR_SPACE}"
[ -n "$VAR_VPN" ] && echo -e "${BUL}${BWHI}VPN (${VPN_IFACE})${SEP}${WHI}${VAR_VPN}"
[ -n "$VAR_UFW" ] && echo -e "${BUL}${BWHI}UFW${SEP}${WHI}${VAR_UFW}"
[ -n "$VAR_DOCKER" ] && echo -e "${BUL}${BWHI}Docker${SEP}${WHI}${VAR_DOCKER}"
[ -n "$VAR_FAILED_UNITS" ] && echo -e "${BUL}${BWHI}Failed Units${SEP}${WHI}${VAR_FAILED_UNITS}"
[ -n "$VAR_REBOOT" ] && echo -e "${BUL}${BWHI}Reboot Required${SEP}${WHI}${VAR_REBOOT}"
echo -e "${BUL}${BWHI}Weather${SEP}${WHI}${VAR_WEATHER}"
echo -e "${BUL}${BWHI}Updates${SEP}${WHI}${VAR_AVAIL_UPDATES}"
[ -n "$VAR_LAST_APT" ] && echo -e "${BUL}${BWHI}Last Apt Update${SEP}${WHI}${VAR_LAST_APT}"
[ -n "$VAR_LAST_LOGIN" ] && echo -e "${BUL}${BWHI}Last Login${SEP}${WHI}${VAR_LAST_LOGIN}"
[ -n "$VAR_LAST_FAIL" ] && echo -e "${BUL}${BWHI}Last Failure${SEP}${WHI}${VAR_LAST_FAIL}"
[ -n "$VAR_F2B_BANNED" ] && echo -e "${BUL}${BWHI}fail2ban Banned${SEP}${WHI}${VAR_F2B_BANNED}"
echo -e "$LIN${RST}\n"

check_under_voltage
exit 0
