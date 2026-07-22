#!/bin/sh

zfs_filesystem_exists()
{
	zfs list -t filesystem "$1" 2>/dev/null | grep -q "^$1" || return 1
	tell_status "$1 filesystem exists"
	return 0
}

zfs_snapshot_exists()
{
	if zfs list -t snapshot "$1" 2>/dev/null | grep -q "$1"; then
		echo "$1 snapshot exists"
		return
	fi
	false
}

zfs_mountpoint_exists()
{
	zfs list -t filesystem "$1" 2>/dev/null | grep -q "$1\$" || return 1
	echo "$1 mountpoint exists"
	return 0
}

zfs_create_fs()
{
	# snapshot /data before provisioning
	if zfs_filesystem_exists "$1"; then
		[ "${ZFS_SNAPSHOT_DATA:-0}" = 0 ] ||
			[ "$(zfs list -Hpo written "$1")" = 0 ] ||
				echo_do \
				zfs snapshot "$1@before-$PROVISION_TIMESTAMP"
		return
	fi

	if [ -n "${2:-}" ] && zfs_mountpoint_exists "$2"; then return; fi

	if echo "$1" | grep -q "$ZFS_DATA_VOL"; then
		if ! zfs_filesystem_exists "$ZFS_DATA_VOL"; then
			echo_do \
			zfs create -o mountpoint="$ZFS_DATA_MNT" "$ZFS_DATA_VOL" || exit 1
		fi
	fi

	if echo "$1" | grep -q "$ZFS_JAIL_VOL"; then
		if ! zfs_filesystem_exists "$ZFS_JAIL_VOL"; then
			echo_do \
			zfs create -o mountpoint="$ZFS_JAIL_MNT" "$ZFS_JAIL_VOL" || exit 1
		fi
	fi

	if [ -z "$2" ]; then
		echo_do \
		zfs create "$1" || exit 1
		echo "done"
		return
	fi

	echo_do \
	zfs create -o mountpoint="$2" "$1" || exit 1
	echo "done"
}

zfs_destroy_fs()
{
	local _fs="$1"
	local _flags=${2-}

	if ! zfs_filesystem_exists "$_fs"; then return; fi

	if [ -n "$_flags" ]; then
		echo_do \
		zfs destroy "$_flags" "$_fs" || exit 1
	else
		echo_do \
		zfs destroy "$_fs" || exit 1
	fi
}

base_snapshot_exists()
{
	if zfs_snapshot_exists "$BASE_SNAP"; then
		return 0
	fi

	echo "$BASE_SNAP does not exist, use 'provision base' to create it"
	return 1
}

rename_staged_to_ready()
{
	local _new_vol="$ZFS_JAIL_VOL/${1}.ready"

	# remove stages that failed promotion
	zfs_destroy_fs "$_new_vol"

	# get the wait over with before shutting down production jail
	local _tries=0
	local _zfs_rename="zfs rename $ZFS_JAIL_VOL/stage $_new_vol"
	echo "$_zfs_rename"
	until $_zfs_rename; do
		if [ "$_tries" -gt 3 ]; then
			echo "trying to force rename"
			_zfs_rename="zfs rename -f $ZFS_JAIL_VOL/stage $_new_vol"
		fi
		echo "waiting for ZFS filesystem to quiet ($_tries)"
		/bin/sync
		_tries=$((_tries + 1))
		sleep 2
	done
}

rename_active_to_last()
{
	local ACTIVE="$ZFS_JAIL_VOL/$1"
	local LAST="$ACTIVE.last"

	zfs_destroy_fs "$LAST" -r  # because of snapshots

	if ! zfs_filesystem_exists "$ACTIVE"; then return; fi

	local _tries=0
	local _zfs_rename="zfs rename $ACTIVE $LAST"
	until echo_do $_zfs_rename; do
		if [ "$_tries" -gt 3 ]; then
			echo "trying to force rename ($_tries)"
			_zfs_rename="zfs rename -f $ACTIVE $LAST"
		fi
		echo_do \
		/bin/sync
		echo "waiting for ZFS filesystem to quiet ($_tries)"
		_tries=$((_tries + 1))
		sleep 2
	done
}

rename_ready_to_active()
{
	echo "zfs rename $ZFS_JAIL_VOL/${1}.ready $ZFS_JAIL_VOL/$1"
	echo_do \
	zfs rename "$ZFS_JAIL_VOL/${1}.ready" "$ZFS_JAIL_VOL/$1" || exit 1
}
