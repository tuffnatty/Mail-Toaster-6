#!/bin/sh

# bump version when a change in mail toaster effects provision scripts
mt6_version() { echo "20260403"; }

# cleaner output
red() { printf "\033[31m"; }
dark_green() { printf "\033[32m"; }
green() { printf "\033[92m"; }
yellow() { printf "\033[33m"; }
normal() { printf "\033[0m"; }

dumbquote() { printf '%s' "$1" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/"; }  # http://www.etalabs.net/sh_tricks.html
quote() {
	local _s _sep=
	# shellcheck disable=SC3050
	if _s="$(printf ' %q' "$@" 2>/dev/null)"; then
		printf '%s' "${_s# }"
	else
		for _arg; do
			case "$_arg" in
				""|*[!A-Za-z0-9@%_:,./=+-]*) printf "$_sep%s" "$(dumbquote "$_arg")" ;;
				*) printf "$_sep%s" "$_arg" ;;
			esac
			_sep=' '
		done
	fi
}

echo_do()
{
	printf '%s\n' "$(dark_green)$(quote "$@")$(normal)" 1>&2
	"$@"
	return $?
}

tell_status() { yellow; echo; echo "   ***   $1   ***"; echo; normal; } 1>&2

mt6_version_check()
{
	if [ "$(uname)" != 'FreeBSD' ]; then return; fi

	if [ -d ".git" ]; then echo "v: $(mt6_version)"; return; fi

	local _github
	_github=$(fetch -o - -q "$TOASTER_SRC_URL/include/util.sh" | grep '^mt6_version(' | cut -f2 -d'"')
	if [ -z "$_github" ]; then
		echo "v: <failed lookup>"
		return
	else
		echo "v: $_github"
	fi

	local _this
	_this="$(mt6_version)"
	if [ -n "$_this" ] && [ "$_this" -lt "$_github" ]; then
		# disable updates
		return
		#echo "NOTICE: updating mail-toaster.sh"
		#mt6-update
	fi
}

dec_to_hex() { printf '%04x\n' "$1"; }

store_config()
{
	# $1 - path to config file, $2 - operation, STDIN is file contents
	local _operation=${2:-""} _data

	if [ ! -d "$(dirname "$1")" ]; then
		echo_do \
		mkdir -p "$(dirname "$1")"
	fi

	if [ ! -f "$1.mt6" ]; then
		echo_do tee "$1.mt6"
	else
		# minimize filesystem diff
		[ "${_data:="$(cat)"}" = "$(cat "$1.mt6")" ] ||
			printf '%s' "$_data" | echo_do tee "$1.mt6"
	fi >/dev/null

	if [ ! -f "$1" ] || [ "$_operation" = "overwrite" ]; then
		# minimize FS diff
		if [ -f "$1" ] && diff -q "$1" "$1.mt6" >/dev/null 2>&1; then
			tell_status "$1 has not changed" 
			return 0
		fi
		tell_status "installing $1"
		echo_do \
		cp "$1.mt6" "$1"
	elif [ "$_operation" = "append" ]; then
		echo_do tee -a "$1" < "$1.mt6" >/dev/null
	else
		tell_status "preserving $1"
	fi
}

store_exec()
{
	# $1 - path to file, STDIN is file contents
	if [ ! -d "$(dirname "$1")" ]; then
		echo_do \
		mkdir -p "$(dirname "$1")" || exit 1
	fi

	tell_status "installing $1"
	cat - > "$1" || exit 1
	chmod 755 "$1"
}

get_random_pass()
{
	local _pass_len=${1:-"14"}
	local _strength=${2:-"good"}

	# Password Entropy = log2(charset_len^pass_len)
	case "$_strength" in
		strong)
			# https://unix.stackexchange.com/questions/230673/how-to-generate-a-random-string
			# more entropy with 94 ASCII chars but special chars are often problematic
			LC_ALL=C tr -dc '[:graph:]' </dev/urandom 2>/dev/null | head -c "$_pass_len"
			;;
		safe)
			# good entropy, limited by 62 alpha-num characters (no symbols)
			LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom 2>/dev/null | head -c "$_pass_len"
			;;
		*)
			# default, good, limited by base64 charset
			openssl rand -base64 "$((_pass_len + 4))" | head -c "$_pass_len"
			;;
	esac

	echo
}

freebsd_major()
{
	# with a root dir, report the target jail's version rather than the host's
	if [ -n "$1" ] && [ -x "$1/bin/freebsd-version" ]; then
		chroot "$1" /bin/freebsd-version | cut -f1 -d.
	else
		/bin/freebsd-version | cut -f1 -d.
	fi
}

configure_pkg_latest()
{
	local REPODIR="$1/usr/local/etc/pkg/repos"
	if [ -f "$REPODIR/FreeBSD.conf" ]; then return; fi

	configure_pkg_repos "$1"
}

repo_conf() { store_config "$REPODIR/$1.conf" "overwrite"; } <<EO_REPO_CONF
$1: {
	url: "$2",
	priority: $3,
	enabled: $4
}
EO_REPO_CONF

configure_pkg_repos() {
	local _root="$1"

	# Our desired config:
	# FreeBSD.conf: default priority
	# FreeBSD-kmods.conf: enabled=no for jails
	# FreeBSD-base.conf: default priority, enabled=yes for pkgbase jails
	# MT6.conf: priority=5, bsd_cache should be running
	# MT6-kmods.conf: priority=5, bsd_cache should be running, enabled=no for jails
	# MT6-base.conf: name=FreeBSD-base priority=5, pkgbase, bsd_cache should be running
	# $PKG_REPO_NAME.conf: priority=10
	local _base_on=no _cache_on=no _kmods_on=no _cache_base_on=no _cache_kmods_on=no
	[ -n "$_root" ] || _kmods_on=yes
	[ "${TOASTER_PKGBASE:-0}" = 0 ] || _base_on=yes
	if jail_is_running bsd_cache; then
		tell_status "switching pkg to bsd_cache"
		_cache_on=yes
		_cache_kmods_on="$_kmods_on"
		_cache_base_on="$_base_on"
	fi

	local REPODIR="$1/usr/local/etc/pkg/repos"

	local _repo_name="FreeBSD-ports"
	if [ "$(freebsd_major "$1")" -lt "15" ]; then _repo_name="FreeBSD"; fi

	tell_status "switching pkg from quarterly to latest"

	local _fbsd_url="pkg+http://pkg.FreeBSD.org"
	local _ports="\${ABI}/$TOASTER_PKG_BRANCH"
	local _kmods="\${ABI}/kmods_${TOASTER_PKG_BRANCH}_\${VERSION_MINOR}"
	local _base="\${ABI}/base_release_\${VERSION_MINOR}"

	[ -f "$REPODIR/$_repo_name.conf" ] ||  # preserve main conf
	repo_conf "$_repo_name"		"$_fbsd_url/$_ports"	0 yes
	repo_conf "$_repo_name-kmods"	"$_fbsd_url/$_kmods"	0 "$_kmods_on"
	repo_conf FreeBSD-base		"$_fbsd_url/$_base"	0 "$_base_on"

	repo_conf MT6			"http://pkg/$_ports"	5 "$_cache_on"
	repo_conf MT6-kmods		"http://pkg/$_kmods"	5 "$_cache_kmods_on"
	repo_conf MT6-base		"http://pkg/$_base"	5 "$_cache_base_on"

	[ -z "$PKG_REPO_NAME" ] || [ -z "$PKG_REPO_URL" ] ||
	repo_conf "$PKG_REPO_NAME"	"$PKG_REPO_URL/$_ports"	10 yes
}

preserve_file()
{
	local _jail_name=$1
	local _file_path=$2

	local _active_cfg="$ZFS_JAIL_MNT/$_jail_name/$_file_path"
	local _stage_cfg="${STAGE_MNT}/$_file_path"

	if [ -f "$_active_cfg" ]; then
		tell_status "preserving $_active_cfg"
		[ -d "$(dirname "$_stage_cfg")" ] || echo_do mkdir -p "$(dirname "$_stage_cfg")"
		echo_do \
		cp -p "$_active_cfg" "$_stage_cfg" || return 1
		return
	fi

	if [ -d "$ZFS_JAIL_MNT/${_jail_name}.last" ]; then
		preserve_file "${_jail_name}.last" "$_file_path"
	fi
}

reverse_list()
{
	local _rev_list=""
	for _j in "$@"; do
		_rev_list="${_j} ${_rev_list}"
	done
	echo "$_rev_list"
}

enable_bsd_cache()
{
	if ! jail_is_running bsd_cache; then return; fi
	if ! jail_is_running dns; then return; fi

	# assure services are available
	sockstat -4 -6 -p 80 -q -j bsd_cache | grep -q . || return
	sockstat -4 -6 -p 53 -q -j dns | grep -q . || return

	tell_status "enabling bsd_cache for ${1:-stage}"

	local _root="${1:-"$STAGE_MNT"}"
	store_config "$_root/etc/resolv.conf" "overwrite" <<EO_RESOLV
nameserver $(get_jail_ip dns)
nameserver $(get_jail_ip6 dns)
EO_RESOLV

	configure_pkg_repos "$_root"

	local _repo_dir="$_root/usr/local/etc/pkg/repos"
	store_config "$_repo_dir/MT6-base.conf" <<EO_PKG_MT6_BASE
MT6-base: {
	url: "http://pkg/\${ABI}/base_release_\${VERSION_MINOR}",
	enabled: yes
}
EO_PKG_MT6_BASE

	# cache pkg audit vulnerability db
	sed_inplace \
		-e '/^#VULNXML_SITE/ s/^#//' \
		-e '/^VULNXML_SITE/ s/vuxml.freebsd.org/vulnxml/' \
		"$_root/usr/local/etc/pkg.conf"

	sed_inplace -e '/^ServerName/ s/update.FreeBSD.org/freebsd-update/' \
		"$_root/etc/freebsd-update.conf"
}

contains() { case "$1" in *"$2"*) ;; *) return 1 ;; esac; }

dirname() {
	# compatible with dirname(1) but several orders of magnitude faster
	[ $# -gt 0 ] || return 1
	local _arg _s1 _s2
	for _arg; do
		_s1="$(rstrip / "$_arg")"
		_s2="$(rstrip / "${_s1%/*}")"
		case "$_arg" in
			/*)	[ -n "$(lstrip / "$_s2")" ] || _s2=/ ;;
			*)	[ -n "${_s2#"$_s1"}" ] || _s2=. ;;
		esac
		printf '%s\n' "$_s2"
	done
}

lstrip() {
	local _s="$2" _next
	while { _next="${_s#"$1"}"; [ "$_next" != "$_s" ]; } do _s="$_next"; done
	printf '%s' "$_s"
}

rstrip() {
	local _s="$2" _next
	while { _next="${_s%"$1"}"; [ "$_next" != "$_s" ]; } do _s="$_next"; done
	printf '%s' "$_s"
}

sed_replacement_quote() { printf "%s" "$1" | sed -E 's,([&\\/]),\\\1,g'; }
