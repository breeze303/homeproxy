#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

NAME="homeproxy"
FETCH_BACKEND=""

RESOURCES_DIR="/etc/$NAME/resources"
mkdir -p "$RESOURCES_DIR"

RUN_DIR="/var/run/$NAME"
LOG_PATH="$RUN_DIR/$NAME.log"
mkdir -p "$RUN_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG_PATH"
}

to_upper() {
	echo -e "$1" | tr "[a-z]" "[A-Z]"
}

init_fetch_backend() {
	if [ -n "$FETCH_BACKEND" ]; then
		return 0
	fi

	if command -v uclient-fetch >/dev/null 2>&1; then
		FETCH_BACKEND="uclient-fetch"
		return 0
	fi

	if command -v wget >/dev/null 2>&1; then
		FETCH_BACKEND="wget"
		return 0
	fi

	return 1
}

fetch_stdout() {
	local url="$1"
	local timeout="$2"
	local header="$3"

	if [ "$FETCH_BACKEND" = "uclient-fetch" ]; then
		if [ -n "$header" ]; then
			uclient-fetch -q -T "$timeout" -H "$header" -O - "$url" 2>/dev/null
		else
			uclient-fetch -q -T "$timeout" -O - "$url" 2>/dev/null
		fi
		return $?
	fi

	if [ -n "$header" ]; then
		wget --timeout="$timeout" -q --header="$header" -O- "$url" 2>/dev/null
	else
		wget --timeout="$timeout" -q -O- "$url" 2>/dev/null
	fi
}

fetch_file() {
	local url="$1"
	local output="$2"
	local timeout="$3"
	local header="$4"

	if [ "$FETCH_BACKEND" = "uclient-fetch" ]; then
		if [ -n "$header" ]; then
			uclient-fetch -q -T "$timeout" -H "$header" -O "$output" "$url" 2>/dev/null
		else
			uclient-fetch -q -T "$timeout" -O "$output" "$url" 2>/dev/null
		fi
		return $?
	fi

	if [ -n "$header" ]; then
		wget --timeout="$timeout" -q --header="$header" -O "$output" "$url" 2>/dev/null
	else
		wget --timeout="$timeout" -q -O "$output" "$url" 2>/dev/null
	fi
}

check_list_update() {
	local listtype="$1"
	local listrepo="$2"
	local listref="$3"
	local listname="$4"
	local lock="$RUN_DIR/update_resources-$listtype.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"
	local token_header=""

	exec 200>"$lock"
	if ! flock -n 200 &> "/dev/null"; then
		log "[$(to_upper "$listtype")] A task is already running."
		return 2
	fi

	if ! init_fetch_backend; then
		log "[$(to_upper "$listtype")] No compatible fetch backend found (uclient-fetch/wget)."
		return 1
	fi

	[ -z "$github_token" ] || token_header="Authorization: Bearer $github_token"
	local list_info
	if ! list_info="$(fetch_stdout "https://api.github.com/repos/$listrepo/commits?sha=$listref&path=$listname&per_page=1" 10 "$token_header")" || [ -z "$list_info" ]; then
		log "[$(to_upper "$listtype")] Failed to get the latest version, please retry later."
		return 1
	fi

	local list_sha="$(echo -e "$list_info" | jsonfilter -qe "@[0].sha")"
	local list_ver="$(echo -e "$list_info" | jsonfilter -qe "@[0].commit.message" | grep -Eo "[0-9-]+" | tr -d '-')"
	if [ -z "$list_sha" ] || [ -z "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Failed to get the latest version, please retry later."
		return 1
	fi

	local local_list_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_list_ver" = "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Current version: $list_ver."
		log "[$(to_upper "$listtype")] You're already at the latest version."
		return 3
	else
		log "[$(to_upper "$listtype")] Local version: $local_list_ver, latest version: $list_ver."
	fi

	if ! fetch_file "https://fastly.jsdelivr.net/gh/$listrepo@$list_sha/$listname" "$RUN_DIR/$listname" 10 || [ ! -s "$RUN_DIR/$listname" ]; then
		rm -f "$RUN_DIR/$listname"
		log "[$(to_upper "$listtype")] Update failed."
		return 1
	fi

	mv -f "$RUN_DIR/$listname" "$RESOURCES_DIR/$listtype.${listname##*.}"
	echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
	log "[$(to_upper "$listtype")] Successfully updated."

	return 0
}

case "$1" in
"china_ip4")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv4.txt"
	;;
"china_ip6")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv6.txt"
	;;
"gfw_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"
	;;
"china_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt" && \
		sed -i -e "s/full://g" -e "/:/d" "$RESOURCES_DIR/china_list.txt"
	;;
*)
	echo -e "Usage: $0 <china_ip4 / china_ip6 / gfw_list / china_list>"
	exit 1
	;;
esac
