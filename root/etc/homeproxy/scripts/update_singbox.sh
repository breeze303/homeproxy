#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 ImmortalWrt.org

NAME="homeproxy"
RUN_DIR="/var/run/$NAME"
LOCK_PATH="$RUN_DIR/update_singbox.lock"
STATUS_PATH="$RUN_DIR/singbox_update.status.json"

TARGET_BIN="/usr/bin/sing-box"
TARGET_DIR="/usr/bin"

GITHUB_REPO="SagerNet/sing-box"
GITHUB_API="https://api.github.com/repos/$GITHUB_REPO/releases/latest"

TMP_DIR=""
STAGED_BIN=""

INSTALLED_VERSION=""
CANDIDATE_VERSION=""
RELEASE_TAG=""
RELEASE_URL=""
ASSET_NAME=""
ASSET_URL=""
ASSET_SIZE=""
ARCH=""
ASSET_ARCH=""
FETCH_BACKEND=""

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

write_status() {
	local code="$1"
	local phase="$2"
	local detail="$3"
	local now
	local tmp_status

	now="$(date +%s)"
	tmp_status="$(mktemp "$RUN_DIR/.singbox_update_status.XXXXXX")" || return 1

	cat > "$tmp_status" <<-EOF
	{
	  "ok": true,
	  "code": "$(json_escape "$code")",
	  "phase": "$(json_escape "$phase")",
	  "installed_version": "$(json_escape "$INSTALLED_VERSION")",
	  "candidate_version": "$(json_escape "$CANDIDATE_VERSION")",
	  "release_tag": "$(json_escape "$RELEASE_TAG")",
	  "release_url": "$(json_escape "$RELEASE_URL")",
	  "asset_name": "$(json_escape "$ASSET_NAME")",
	  "arch": "$(json_escape "$ARCH")",
	  "detail": "$(json_escape "$detail")",
	  "updated_at": $now
	}
	EOF

	mv -f "$tmp_status" "$STATUS_PATH"
}

print_status() {
	mkdir -p "$RUN_DIR"

	if [ -f "$STATUS_PATH" ]; then
		cat "$STATUS_PATH"
	else
		write_status "already_latest" "done" "No active update task."
		cat "$STATUS_PATH"
	fi
}

cleanup() {
	[ -z "$STAGED_BIN" ] || rm -f "$STAGED_BIN"
	[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}

get_release_value() {
	local file="$1"
	local key="$2"
	grep -E "^$key=" "$file" 2>/dev/null | awk -F '=' 'NR==1 {gsub(/\"/, "", $2); print $2}'
}

need_tools() {
	local missing=""
	local t

	for t in flock jsonfilter tar mktemp mv cp chmod chown rm awk grep df uname wc sed date cat; do
		if ! command -v "$t" >/dev/null 2>&1; then
			missing="$missing $t"
		fi
	done

	if [ -n "$missing" ]; then
		write_status "tool_missing" "check" "Missing required tools:${missing}"
		return 1
	fi

	if ! init_fetch_backend; then
		write_status "tool_missing" "check" "Missing required fetch backend: uclient-fetch or wget."
		return 1
	fi

	if [ ! -x "$TARGET_BIN" ] || [ ! -x "/etc/init.d/homeproxy" ]; then
		write_status "tool_missing" "check" "Missing required runtime binaries: $TARGET_BIN or /etc/init.d/homeproxy."
		return 1
	fi

	return 0
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

	if [ "$FETCH_BACKEND" = "uclient-fetch" ]; then
		uclient-fetch -q -T "$timeout" -O - "$url" 2>/dev/null
		return $?
	fi

	wget --timeout="$timeout" -qO- "$url" 2>/dev/null
}

fetch_file() {
	local url="$1"
	local output="$2"
	local timeout="$3"

	if [ "$FETCH_BACKEND" = "uclient-fetch" ]; then
		uclient-fetch -q -T "$timeout" -O "$output" "$url" 2>/dev/null
		return $?
	fi

	wget --timeout="$timeout" -q -O "$output" "$url" 2>/dev/null
}

normalize_version() {
	local v="$1"
	v="${v#v}"
	v="${v%%-*}"
	printf '%s' "$v"
}

version_gt() {
	local a b
	a="$(normalize_version "$1")"
	b="$(normalize_version "$2")"

	awk -v A="$a" -v B="$b" '
	BEGIN {
		nA = split(A, a, ".");
		nB = split(B, b, ".");
		for (i = 1; i <= 4; i++) {
			av = (i <= nA && a[i] ~ /^[0-9]+$/) ? a[i] + 0 : 0;
			bv = (i <= nB && b[i] ~ /^[0-9]+$/) ? b[i] + 0 : 0;
			if (av > bv) exit 0;
			if (av < bv) exit 1;
		}
		exit 1;
	}'
}

detect_installed_version() {
	if [ -x "$TARGET_BIN" ]; then
		INSTALLED_VERSION="$($TARGET_BIN version -n 2>/dev/null | awk 'NR==1 {print $1}')"
		[ -n "$INSTALLED_VERSION" ] || INSTALLED_VERSION="$($TARGET_BIN version 2>/dev/null | awk 'NR==1 {print $3}')"
	fi

	[ -n "$INSTALLED_VERSION" ] || INSTALLED_VERSION="v0.0.0"
}

detect_arch() {
	local uname_arch board openwrt_arch distrib_arch

	uname_arch="$(uname -m 2>/dev/null)"
	board="$(get_release_value "/usr/lib/os-release" "OPENWRT_BOARD")"
	openwrt_arch="$(get_release_value "/usr/lib/os-release" "OPENWRT_ARCH")"
	distrib_arch="$(get_release_value "/etc/openwrt_release" "DISTRIB_ARCH")"

	case "$uname_arch" in
	x86_64|amd64)
		ASSET_ARCH="amd64-musl"
		ARCH="x86_64"
		;;
	i386|i486|i586|i686|x86)
		ASSET_ARCH="386-musl"
		ARCH="x86"
		;;
	aarch64|arm64)
		ASSET_ARCH="arm64-musl"
		ARCH="aarch64"
		;;
	armv8*|arm64v8*)
		ASSET_ARCH="arm64-musl"
		ARCH="armv8"
		;;
	armv7*|armv7l)
		ASSET_ARCH="armv7-musl"
		ARCH="armv7"
		;;
	mips64el*|mips64le*)
		ASSET_ARCH="mips64le-softfloat"
		ARCH="mips64el"
		;;
	mips64*)
		ASSET_ARCH="mips64-softfloat"
		ARCH="mips64"
		;;
	mipsel*)
		ASSET_ARCH="mipsle-softfloat-musl"
		ARCH="mipsel"
		;;
	mips*)
		ASSET_ARCH="mips-softfloat"
		ARCH="mips"
		;;
	riscv64*)
		ASSET_ARCH="riscv64-musl"
		ARCH="riscv64"
		;;
	*)
		ASSET_ARCH=""
		ARCH="$uname_arch"
		;;
	esac

	if [ -z "$ASSET_ARCH" ] && printf '%s %s %s' "$board" "$openwrt_arch" "$distrib_arch" | grep -qi "rockchip"; then
		ASSET_ARCH="arm64-musl"
		ARCH="rockchip"
	fi

	if [ -z "$ASSET_ARCH" ] && printf '%s %s' "$openwrt_arch" "$distrib_arch" | grep -Eqi '(^|_)armv7|arm_cortex-a7'; then
		ASSET_ARCH="armv7-musl"
		ARCH="armv7"
	fi

	if [ -z "$ASSET_ARCH" ] && printf '%s %s' "$openwrt_arch" "$distrib_arch" | grep -Eqi '(^|_)aarch64|armv8|arm_cortex-a53'; then
		ASSET_ARCH="arm64-musl"
		ARCH="armv8"
	fi

	[ -n "$ASSET_ARCH" ]
}

check_space_kb() {
	local target="$1"
	local needed_kb="$2"
	local free_kb

	free_kb="$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}')"
	[ -n "$free_kb" ] || return 1

	[ "$free_kb" -ge "$needed_kb" ]
}

get_release_metadata() {
	local release_json release_draft release_prerelease version_plain i name

	release_json="$(fetch_stdout "$GITHUB_API" 20)"
	[ -n "$release_json" ] || {
		write_status "download_failed" "check" "Failed to fetch latest release metadata."
		return 1
	}

	RELEASE_TAG="$(printf '%s' "$release_json" | jsonfilter -qe '@.tag_name' 2>/dev/null)"
	RELEASE_URL="$(printf '%s' "$release_json" | jsonfilter -qe '@.html_url' 2>/dev/null)"
	release_draft="$(printf '%s' "$release_json" | jsonfilter -qe '@.draft' 2>/dev/null)"
	release_prerelease="$(printf '%s' "$release_json" | jsonfilter -qe '@.prerelease' 2>/dev/null)"

	if [ -z "$RELEASE_TAG" ] || [ "$release_draft" = "true" ] || [ "$release_prerelease" = "true" ]; then
		write_status "asset_not_found" "check" "No stable release metadata available."
		return 1
	fi

	version_plain="$(normalize_version "$RELEASE_TAG")"
	ASSET_NAME="sing-box-$version_plain-linux-$ASSET_ARCH.tar.gz"

	i=0
	while :; do
		name="$(printf '%s' "$release_json" | jsonfilter -qe "@.assets[$i].name" 2>/dev/null)"
		[ -n "$name" ] || break

		if [ "$name" = "$ASSET_NAME" ]; then
			ASSET_URL="$(printf '%s' "$release_json" | jsonfilter -qe "@.assets[$i].browser_download_url" 2>/dev/null)"
			ASSET_SIZE="$(printf '%s' "$release_json" | jsonfilter -qe "@.assets[$i].size" 2>/dev/null)"
			break
		fi

		i=$((i + 1))
	done

	if [ -z "$ASSET_URL" ]; then
		write_status "asset_not_found" "check" "Stable release found but no matching asset for $ARCH ($ASSET_ARCH)."
		return 1
	fi

	return 0
}

precheck_update() {
	local detail

	detect_installed_version

	if ! need_tools; then
		return 1
	fi

	if ! detect_arch; then
		write_status "arch_unsupported" "check" "Unsupported architecture: $(uname -m 2>/dev/null)."
		return 1
	fi

	if ! get_release_metadata; then
		return 1
	fi

	CANDIDATE_VERSION="$RELEASE_TAG"

	if ! version_gt "$CANDIDATE_VERSION" "$INSTALLED_VERSION"; then
		detail="Installed version ($INSTALLED_VERSION) is already latest or newer than stable release ($CANDIDATE_VERSION)."
		write_status "already_latest" "check" "$detail"
		return 2
	fi

	detail="Stable update available: $INSTALLED_VERSION -> $CANDIDATE_VERSION ($ASSET_NAME)."
	write_status "update_available" "check" "$detail"
	return 0
}

do_update() {
	local archive extract_dir candidate_bin candidate_version_now candidate_size needed_kb needed_tmp_kb
	local target_mode target_owner
	local rc

	precheck_update
	rc="$?"
	[ "$rc" -eq 0 ] || return "$rc"

	needed_tmp_kb=32768
	if [ -n "$ASSET_SIZE" ] && [ "$ASSET_SIZE" -gt 0 ] 2>/dev/null; then
		needed_tmp_kb=$(( (ASSET_SIZE * 2 / 1024) + 8192 ))
	fi

	if ! check_space_kb "/tmp" "$needed_tmp_kb"; then
		write_status "no_space" "download" "Insufficient /tmp free space for download and extraction."
		return 1
	fi

	TMP_DIR="$(mktemp -d "/tmp/singbox_update.XXXXXX")" || {
		write_status "download_failed" "download" "Failed to allocate temporary directory."
		return 1
	}

	archive="$TMP_DIR/$ASSET_NAME"
	write_status "downloading" "download" "Downloading $ASSET_NAME from stable release."
	if ! fetch_file "$ASSET_URL" "$archive" 30 || [ ! -s "$archive" ]; then
		write_status "download_failed" "download" "Failed to download release asset."
		return 1
	fi

	write_status "extracting" "extract" "Extracting release archive."
	if ! tar -xzf "$archive" -C "$TMP_DIR" >/dev/null 2>&1; then
		write_status "extract_failed" "extract" "Failed to extract release archive."
		return 1
	fi

	extract_dir="$TMP_DIR/${ASSET_NAME%.tar.gz}"
	candidate_bin="$extract_dir/sing-box"
	[ -f "$candidate_bin" ] || candidate_bin="$TMP_DIR/sing-box"

	if [ ! -f "$candidate_bin" ]; then
		write_status "extract_failed" "extract" "Extracted archive does not contain sing-box binary."
		return 1
	fi

	chmod 0755 "$candidate_bin" 2>/dev/null
	candidate_version_now="$($candidate_bin version -n 2>/dev/null | awk 'NR==1 {print $1}')"
	if [ -z "$candidate_version_now" ]; then
		write_status "binary_invalid" "validate" "Extracted binary is not executable or has invalid version output."
		return 1
	fi

	if ! version_gt "$candidate_version_now" "$INSTALLED_VERSION"; then
		write_status "already_latest" "check" "Candidate version ($candidate_version_now) is not newer than installed ($INSTALLED_VERSION)."
		return 2
	fi

	candidate_size="$(wc -c < "$candidate_bin" 2>/dev/null)"
	[ -n "$candidate_size" ] || candidate_size=0
	needed_kb=$(( (candidate_size + 1023) / 1024 + 1024 ))
	if ! check_space_kb "$TARGET_DIR" "$needed_kb"; then
		write_status "no_space" "install" "Insufficient target filesystem free space for atomic install."
		return 1
	fi

	write_status "installing" "install" "Installing new sing-box binary atomically."
	STAGED_BIN="$(mktemp "$TARGET_DIR/.sing-box.new.XXXXXX")" || {
		write_status "install_failed" "install" "Failed to create atomic staging file in target directory."
		return 1
	}

	if ! cp "$candidate_bin" "$STAGED_BIN"; then
		write_status "install_failed" "install" "Failed to stage new binary."
		return 1
	fi

	target_mode="755"
	target_owner="0:0"
	if [ -f "$TARGET_BIN" ] && command -v stat >/dev/null 2>&1; then
		target_mode="$(stat -c '%a' "$TARGET_BIN" 2>/dev/null)"
		target_owner="$(stat -c '%u:%g' "$TARGET_BIN" 2>/dev/null)"
	fi
	[ -n "$target_mode" ] || target_mode="755"
	[ -n "$target_owner" ] || target_owner="0:0"

	if ! chmod "$target_mode" "$STAGED_BIN"; then
		write_status "install_failed" "install" "Failed to set staged binary mode."
		return 1
	fi

	if ! chown "$target_owner" "$STAGED_BIN" 2>/dev/null; then
		write_status "install_failed" "install" "Failed to set staged binary ownership."
		return 1
	fi

	if ! mv -f "$STAGED_BIN" "$TARGET_BIN"; then
		write_status "install_failed" "install" "Atomic replacement to /usr/bin/sing-box failed."
		return 1
	fi
	STAGED_BIN=""

	CANDIDATE_VERSION="$candidate_version_now"
	write_status "validating" "validate" "Validating installed binary and runtime config compatibility."

	if ! "$TARGET_BIN" version -n >/dev/null 2>&1; then
		write_status "installed_not_activated" "done" "Binary replaced but post-install version check failed."
		return 1
	fi

	if ! /etc/init.d/homeproxy validate >/dev/null 2>&1; then
		write_status "validate_failed" "validate" "Generated HomeProxy runtime config validation failed with updated binary."
		write_status "installed_not_activated" "done" "Binary replaced but HomeProxy runtime config validation failed."
		return 1
	fi

	write_status "restarting" "restart" "Validation passed; restarting HomeProxy to activate updated sing-box."
	if ! /etc/init.d/homeproxy restart >/dev/null 2>&1; then
		write_status "restart_failed" "restart" "Binary replaced and validation passed, but HomeProxy restart failed."
		write_status "installed_not_activated" "done" "Binary replaced but HomeProxy restart failed after validation."
		return 1
	fi

	INSTALLED_VERSION="$CANDIDATE_VERSION"
	write_status "success" "done" "Stable sing-box update installed successfully."
	return 0
}

cmd_check() {
	local rc

	mkdir -p "$RUN_DIR"
	exec 200>"$LOCK_PATH" || {
		write_status "busy" "check" "Failed to open updater lock."
		print_status
		return 1
	}

	if ! flock -n 200 >/dev/null 2>&1; then
		write_status "busy" "check" "Another update/check task is running."
		print_status
		return 2
	fi

	precheck_update
	rc="$?"
	print_status
	return "$rc"
}

cmd_start() {
	local rc

	mkdir -p "$RUN_DIR"
	exec 200>"$LOCK_PATH" || {
		write_status "busy" "check" "Failed to open updater lock."
		print_status
		return 1
	}

	if ! flock -n 200 >/dev/null 2>&1; then
		write_status "busy" "check" "Another update/check task is running."
		print_status
		return 2
	fi

	precheck_update
	rc="$?"
	if [ "$rc" -ne 0 ]; then
		print_status
		return "$rc"
	fi

	write_status "started" "check" "Update job accepted and starting background pipeline."
	flock -u 200 >/dev/null 2>&1
	"$0" run >/dev/null 2>&1 &
	print_status
	return 0
}

cmd_run() {
	mkdir -p "$RUN_DIR"
	trap cleanup EXIT INT TERM

	exec 200>"$LOCK_PATH" || {
		write_status "busy" "check" "Failed to open updater lock."
		return 1
	}

	if ! flock -n 200 >/dev/null 2>&1; then
		write_status "busy" "check" "Another update/check task is running."
		return 2
	fi

	do_update
	return $?
}

case "$1" in
check)
	cmd_check
	;;
start)
	cmd_start
	;;
status)
	print_status
	;;
run)
	cmd_run
	;;
*)
	echo "Usage: $0 <check|start|status|run>"
	exit 1
	;;
esac
