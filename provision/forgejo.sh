#!/bin/sh
set -e -u

. mail-toaster.sh
service_config forgejo
export FORGEJO_ADMIN_EMAIL=${FORGEJO_ADMIN_EMAIL:?FORGEJO_ADMIN_EMAIL should be set}
export FORGEJO_ADMIN_PASSWORD=${FORGEJO_ADMIN_PASSWORD:?FORGEJO_ADMIN_PASSWORD should be set}
export FORGEJO_ADMIN_USERNAME=${FORGEJO_ADMIN_USERNAME:?FORGEJO_ADMIN_USERNAME should be set}
export FORGEJO_ATTACHMENT_SIZE_MB=${FORGEJO_ATTACHMENT_SIZE_MB:?FORGEJO_ATTACHMENT_SIZE_MB should be set}
export FORGEJO_BRANDING=${FORGEJO_BRANDING:-"Forgejo: A self-hosted lightweight software forge"}
export FORGEJO_DISABLE_REGISTRATION=${FORGEJO_DISABLE_REGISTRATION:-"true"}
export FORGEJO_DOMAIN=${FORGEJO_DOMAIN:-"localhost"}
export FORGEJO_FROM=${FORGEJO_FROM:?FORGEJO_FROM must be set}
export FORGEJO_SMTP_USER=${FORGEJO_SMTP_USER:-"forgejo"}@"$TOASTER_MAIL_DOMAIN"
export FORGEJO_SMTP_PASS=${FORGEJO_SMTP_PASS:?FORGEJO_SMTP_PASS must be set}
export FORGEJO_SECRET_KEY=${FORGEJO_SECRET_KEY:?FORGEJO_SECRET_KEY should be set}
export FORGEJO_SSH_PORT=${FORGEJO_SSH_PORT:?FORGEJO_SSH_PORT should be set}

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA=""
export JAIL_FSTAB=""

_custom="/usr/local/etc/forgejo"
_product_conf="$_custom/conf/app.ini"
_product_cmd="forgejo -C $_custom -c $_product_conf"

install_forgejo()
{
	GIT_STATIC_UID=211

	echo_stage_exec mkdir -p /data/home
	echo_stage_exec rm -fr /home /usr/home
	echo_stage_exec ln -sfh /data/home /home
	echo_stage_exec ln -sfh /home /usr/home

	echo_stage_exec mkdir -p /data/forgejo/forgejo-repositories
	echo_stage_exec chown $GIT_STATIC_UID:$GIT_STATIC_UID /data/forgejo /data/forgejo/forgejo-repositories
	echo_stage_exec ln -sfh /data/forgejo /var/db/forgejo

	echo_stage_exec mkdir -p /data/log/forgejo
	echo_stage_exec chown $GIT_STATIC_UID:$GIT_STATIC_UID /data/log/forgejo
	echo_stage_exec ln -sfh /data/log/forgejo /var/log/forgejo

	tell_status "installing Forgejo"
	configure_pkg_latest "$STAGE_MNT"
	# After https://github.com/freebsd/freebsd-src/commit/560af6b43e2a86e591e94bea99777630cd5f84fd
	# we need to install FreeBSD-pam
	[ "${TOASTER_PKGBASE:-0}" = 0 ] || stage_pkg_install FreeBSD-pam
	stage_exec pkg install -y sqlite3 forgejo-lts
}

stage_exec_as_git() { jexec -U git stage "$@"; }
echo_stage_exec_as_git() { echo_do jexec -U git stage "$@"; }
configure_forgejo()
{
	tell_status "configuring Forgejo"
	echo_stage_exec pw usermod git -d /home/git -m
	echo_stage_exec_as_git git config --global core.autocrlf input
	echo_stage_exec_as_git git config --global gc.auto 0
	echo_stage_exec_as_git git config --global repack.writeBitmaps true
	echo_stage_exec_as_git mkdir -p /home/git/.ssh

	echo_stage_exec sed -i '' \
		-e '/^APP_NAME / s/Forgejo: A self-hosted lightweight software forge$/'"$(sed_replacement_quote "$FORGEJO_BRANDING")"'/' \
		-e '/^DOMAIN / s/localhost$/'"$FORGEJO_DOMAIN"'/' \
		-e '/^ROOT_URL / s,http://localhost:3000/,https://'"$FORGEJO_DOMAIN"'/,' \
		-e '/^SSH_PORT / s/22$/'"$FORGEJO_SSH_PORT"'/' \
		-e '/^DISABLE_REGISTRATION / s/false$/'"$FORGEJO_DISABLE_REGISTRATION"'/' \
		-e '/^SECRET_KEY / s/CHANGE_ME/'"$FORGEJO_SECRET_KEY"'/' \
		-e '/^INTERNAL_TOKEN / s/ = .*$/ = '"$(sed_replacement_quote "$(stage_exec forgejo generate secret INTERNAL_TOKEN)")"'/' \
		-e '/^\[mailer]/,/^$/ s/^ENABLED = false$/ENABLED = true/' \
		-e '/^REGISTER_EMAIL_CONFIRM / s/false$/true/' \
		-e '/^REQUIRE_SIGNIN_VIEW / s/false$/true/' \
		-e '/^ENABLE_NOTIFY_MAIL / s/false$/true/' \
		-e '/^\[database]$/a\
SQLITE_JOURNAL_MODE = WAL' \
		-e '/^\[log]$/a\
logger.xorm.MODE = \
LOGGER_ROUTER_MODE = file' \
		-e '/^\[mailer]$/a\
PROTOCOL = smtp\
SMTP_ADDR = '"$TOASTER_MSA"'\
SMTP_PORT = 25\
FROM = '"$FORGEJO_FROM"'\
USER = '"$FORGEJO_SMTP_USER@${TOASTER_MAIL_DOMAIN}"'\
PASSWD = `'"$FORGEJO_SMTP_PASS"'`' \
                -e '/^\[server]$/a\
START_SSH_SERVER = true\
SSH_LISTEN_PORT = '"$FORGEJO_SSH_PORT" \
		-e '$a\
[admin]\
DISABLE_REGULAR_ORG_CREATION = true\
[attachment]\
MAX_SIZE = '"$FORGEJO_ATTACHMENT_SIZE_MB"'\
[cors]\
ENABLED = true\
[cron]\
ENABLED = true\
[email.incoming]\
ENABLED = true\
REPLY_TO_ADDRESS = '"$FORGEJO_SMTP_USER+%{token}@$TOASTER_MAIL_DOMAIN"'\
HOST = '"$(get_jail_ip dovecot)"'\
PORT = 143\
USERNAME = '"$FORGEJO_SMTP_USER@${TOASTER_MAIL_DOMAIN}"'\
PASSWORD = '"$FORGEJO_SMTP_PASS"'\
[log.console]\
STDERR = true\
[log.file]\
DAILY_ROTATE = false\
COMPRESS = false\
[ui.meta]\
AUTHOR = '"$FORGEJO_BRANDING"'\
DESCRIPTION = '"$FORGEJO_BRANDING" \
		"$_product_conf"
	echo_stage_exec chown git "$_product_conf"

	echo_stage_exec_as_git $_product_cmd doctor check || { echo "doctor check returned $?" 1>&2; exit 1; }
	echo_stage_exec_as_git $_product_cmd migrate || { echo "migrate returned $?" 1>&2; exit 1; }

	echo_stage_exec_as_git $_product_cmd admin user list --admin

	stage_exec_as_git $_product_cmd admin user list --admin | grep -qvE '^([0-9]|ID)' \
	|| echo_stage_exec_as_git $_product_cmd admin user create \
		--admin \
		--username "$FORGEJO_ADMIN_USERNAME" \
		--password "$FORGEJO_ADMIN_PASSWORD" \
		--email "$FORGEJO_ADMIN_EMAIL" \
		--must-change-password false \
	|| echo "WARNING: could not create admin user?" 1>&2

	stage_sysrc forgejo_enable=YES

	configure_ssh_pf_rdr forgejo "$FORGEJO_SSH_PORT"
}

start_forgejo()
{
	tell_status "starting up Forgejo"
	stage_exec service forgejo start
}

test_forgejo()
{
	tell_status "testing Forgejo"

	sleep 2 && echo_stage_exec_as_git $_product_cmd manager processes
	echo "it worked"
}

tell_settings FORGEJO
base_snapshot_exists || exit 1
create_staged_fs forgejo
start_staged_jail forgejo
install_forgejo
configure_forgejo
start_forgejo
test_forgejo
promote_staged_jail forgejo
