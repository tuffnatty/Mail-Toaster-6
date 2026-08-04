#!/bin/sh
set -e -u

. mail-toaster.sh
service_config sshjail
export SSHJAIL_SSH_PORT=${SSHJAIL_SSH_PORT:?SSHJAIL_SSH_PORT must be set}
export SSHJAIL_DEFAULT_PASSWD=${SSHJAIL_DEFAULT_PASSWD:-""}
export SSHJAIL_USERNAME=${SSHJAIL_USERNAME:-"sshuser"}
export SSHJAIL_UID=${SSHJAIL_UID:?SSHJAIL_UID must be set}
export SSHJAIL_GID=${SSHJAIL_GID:?SSHJAIL_GID must be set}


export BASE_SNAP=EMPTY
export JAIL_CONF_EXTRA="
		mount += \"$ZFS_DATA_MNT/sshjail \$path/data nullfs rw 0 0\";
		devfs_ruleset=2;
		exec.start=\"/usr/sbin/sshd -p $SSHJAIL_SSH_PORT\";
		exec.stop=\"\";"
export JAIL_START_EXTRA=""
export JAIL_FSTAB=""

sshd_keygen_alg()
{
	local alg=$1 ALG
	ALG="$(echo $alg | tr '[:lower:]' '[:upper:]')"
	local keyfile

	case $alg in
	rsa|ecdsa|ed25519)
		keyfile="/etc/ssh/ssh_host_${alg}_key"
		;;
	*)
		return 1
		;;
	esac

	if [ -f "$STAGE_MNT${keyfile}" ] ; then
		echo "$ALG host key exists."
		return 0
	fi

	[ ! -f "$ZFS_JAIL_MNT/sshjail$keyfile" ] || {
		echo_do rsync -a "$ZFS_JAIL_MNT/sshjail$keyfile" "$STAGE_MNT$keyfile"
		return 0
	}
	if [ ! -x /usr/bin/ssh-keygen ] ; then
		echo "/usr/bin/ssh-keygen does not exist."
		return 1
	fi

	echo_do /usr/bin/ssh-keygen -q -t $alg -f "$STAGE_MNT$keyfile" -N ""
	echo_do /usr/bin/ssh-keygen -l -f "$STAGE_MNT$keyfile.pub"
}


sshd_keygen()
{
	sshd_keygen_alg rsa
	sshd_keygen_alg ecdsa
	sshd_keygen_alg ed25519
}

install_sshjail() {
	[ -d "$ZFS_DATA_MNT/sshjail/home" ] || mkdir "$ZFS_DATA_MNT/sshjail/home"

	echo_do mkdir -p "$STAGE_MNT/dev" "$STAGE_MNT/var/empty"
	echo_do chmod 0555 "$STAGE_MNT/var/empty"
	sshd_files="
		/etc/pam.d
		/etc/ssh/sshd_config
		/usr/lib/libasn1.so*
		/usr/lib/libblacklist.so*
		/usr/lib/libcom_err.so*
		/usr/lib/libgssapi_krb5.so*
		/usr/lib/libheimbase.so*
		/usr/lib/libhx509.so*
		/usr/lib/libkrb5.so*
		/usr/lib/libpam.so*
		/usr/lib/libprivateheimipcc.so*
		/usr/lib/libprivateldns.so*
		/usr/lib/libprivatessh.so*
		/usr/lib/libroken.so*
		/usr/lib/libwind.so*
		/usr/lib/libwrap.so*
		/usr/lib/pam*
		/usr/libexec/sshd-auth
		/usr/libexec/sshd-session
		/usr/sbin/sshd
	"
	for F in $sshd_files	\
	; do
		[ -d "$STAGE_MNT${F%/*}" ] || echo_do mkdir -p "$STAGE_MNT${F%/*}"
		echo_do sh -c "rsync -a $BASE_MNT$F $STAGE_MNT${F%/*}"
	done

	echo_do touch \
		"$STAGE_MNT/etc/master.passwd"	\
		"$STAGE_MNT/etc/pwd.db"	\
		"$STAGE_MNT/etc/spwd.db"
	tee "$STAGE_MNT/etc/group" <<EOF
wheel:*:0:root
sshd:*:22:
EOF
	echo_do pw -R "$STAGE_MNT" useradd -n root -u 0 -g 0 -d /var/empty -s /usr/sbin/nologin
	echo_do pw -R "$STAGE_MNT" useradd -n sshd -u 22 -g 22 -d /var/empty -s /usr/sbin/nologin
	#echo_do cap_mkdb "$STAGE_MNT/etc/login.conf"


	echo_do mkdir -p "$STAGE_MNT/usr/share/keys"
	echo_do rsync -a "/usr/share/keys/pkg" "$STAGE_MNT/usr/share/keys/"

	echo_do pkg -r "$STAGE_MNT" install -y -r FreeBSD-base  FreeBSD-runtime

	echo_do chflags 0 \
		"$STAGE_MNT/sbin/init"	\
		"$STAGE_MNT/usr/bin/login"	\
		"$STAGE_MNT/usr/bin/passwd"
	ls "$STAGE_MNT"/usr/sbin
	for F in	\
		"/bin/*"	\
		"/sbin/*"	\
		"/usr/bin/*"	\
		"/usr/sbin/*"	\
		"/usr/share/doc"	\
		"/usr/share/keys/pkg"	\
		"/usr/share/nls/*"	\
		"/usr/libexec/getty"	\
		"/var/cache/pkg/*"	\
		"/var/db/pkg/*"	\
	; do
		echo_do sh -c "rm -fr $STAGE_MNT$F"
	done
	#echo_do rsync -a "$BASE_MNT/bin/cat" "$STAGE_MNT/bin/cat"
	#echo_do rsync -a "$BASE_MNT/usr/bin/login" "$STAGE_MNT/usr/bin/login"
	echo_do rsync -a "$BASE_MNT/usr/bin/passwd" "$STAGE_MNT/usr/bin/passwd"
	echo_do rsync -a "$BASE_MNT/usr/sbin/pwd_mkdb" "$STAGE_MNT/usr/sbin/pwd_mkdb"
	echo_do rsync -a "$BASE_MNT/usr/sbin/sshd" "$STAGE_MNT/usr/sbin/sshd"

	for F in \
		/usr/bin/su /usr/lib/libbsm.so* \
		/etc/login.conf \
		/etc/nsswitch.conf	\
		/lib/libutil.so*	\
		/lib/libcrypto.so*	\
		/lib/libc.so*	\
		/lib/libcrypt.so*	\
		/lib/libz.so*	\
		/lib/libthr.so*	\
		/libexec/ld-elf.so*	\
		/usr/lib/libgssapi.so*	\
		/usr/lib/libssl.so*	\
	; do
		[ -f "$STAGE_MNT$F" ] || echo "$F is missing"
	done

	sshd_keygen
	echo_do tee -a "$STAGE_MNT/etc/hosts" <<EOF
$(get_jail_ip postfixadmin)	postfixadmin
EOF
}

create_staged_fs sshjail

install_sshjail

start_staged_jail
echo '*' | echo_do pw -R "$STAGE_MNT" usermod -n root -H 0
echo_do pw -R "$STAGE_MNT" groupadd -n "$SSHJAIL_USERNAME" -g "$SSHJAIL_GID"

_passwd="$(awk -F: '/^'"$SSHJAIL_USERNAME"':/{print $2;exit} END{exit 1}' "$ZFS_JAIL_MNT/sshjail/etc/master.passwd" || printf '%s' "${SSHJAIL_DEFAULT_PASSWD:-}")"
if [ -z "$_passwd" ]; then
	echo_do pw -R "$STAGE_MNT" useradd -n "$SSHJAIL_USERNAME" -u "$SSHJAIL_UID" -g "$SSHJAIL_GID" -d /data/home/"$SSHJAIL_USERNAME" -m -s /usr/bin/passwd -w random
else
	echo_do pw -R "$STAGE_MNT" useradd -n "$SSHJAIL_USERNAME" -u "$SSHJAIL_UID" -g "$SSHJAIL_GID" -d /data/home/"$SSHJAIL_USERNAME" -m -s /usr/bin/passwd -H 0 <<-EOF_PASSWD
		$_passwd
	EOF_PASSWD
fi
echo_do pkill -j stage sshd

configure_ssh_pf_etc sshjail "$SSHJAIL_SSH_PORT"

TOASTER_PKG_AUDIT=0 promote_staged_jail sshjail
