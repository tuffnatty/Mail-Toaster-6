#!/bin/sh
set -e

. mail-toaster.sh || exit


zfs_create_fs "$ZFS_DATA_VOL/vmail" "$ZFS_DATA_MNT/vmail"
chown "$POSTFIX_MAILBOX_OWNER_UID:$POSTFIX_MAILBOX_OWNER_GID" "$ZFS_DATA_MNT/vmail"
