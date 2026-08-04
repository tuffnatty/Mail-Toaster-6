#!/bin/sh
set -e -u

. mail-toaster.sh
service_config gitea
export GITEA_ADMIN_EMAIL=${GITEA_ADMIN_EMAIL:?GITEA_ADMIN_EMAIL should be set}
export GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD:?GITEA_ADMIN_PASSWORD should be set}
export GITEA_ADMIN_USERNAME=${GITEA_ADMIN_USERNAME:?GITEA_ADMIN_USERNAME should be set}
export GITEA_ATTACHMENT_SIZE_MB=${GITEA_ATTACHMENT_SIZE_MB:?GITEA_ATTACHMENT_SIZE_MB should be set}
export GITEA_BRANDING=${GITEA_BRANDING:-"Gitea: Git with a cup of tea"}
export GITEA_DISABLE_REGISTRATION=${GITEA_DISABLE_REGISTRATION:-"true"}
export GITEA_DOMAIN=${GITEA_DOMAIN:-"localhost"}
export GITEA_FROM=${GITEA_FROM:?GITEA_FROM must be set}
export GITEA_SMTP_USER=${GITEA_SMTP_USER:-"gitea"}@"$TOASTER_MAIL_DOMAIN"
export GITEA_SMTP_PASS=${GITEA_SMTP_PASS:?GITEA_SMTP_PASS must be set}
export GITEA_SECRET_KEY=${GITEA_SECRET_KEY:?GITEA_SECRET_KEY should be set}
export GITEA_SSH_PORT=${GITEA_SSH_PORT:?GITEA_SSH_PORT should be set}

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA=""
export JAIL_FSTAB=""

_custom="/usr/local/etc/gitea"
_product_conf="$_custom/conf/app.ini"
_product_cmd="gitea -C $_custom -c $_product_conf"

install_gitea()
{
	GIT_STATIC_UID=211

	echo_stage_exec mkdir -p /data/home
	echo_stage_exec rm -fr /home /usr/home
	echo_stage_exec ln -sfh /data/home /home
	echo_stage_exec ln -sfh /home /usr/home

	echo_stage_exec mkdir -p /data/gitea/gitea-repositories
	echo_stage_exec chown $GIT_STATIC_UID:$GIT_STATIC_UID /data/gitea /data/gitea/gitea-repositories
	echo_stage_exec ln -sfh /data/gitea /var/db/gitea

	echo_stage_exec mkdir -p /data/log/gitea
	echo_stage_exec chown $GIT_STATIC_UID:$GIT_STATIC_UID /data/log/gitea
	echo_stage_exec ln -sfh /data/log/gitea /var/log/gitea

	tell_status "installing Gitea"
	# After https://github.com/freebsd/freebsd-src/commit/560af6b43e2a86e591e94bea99777630cd5f84fd
	# we need to install FreeBSD-pam
	[ "${TOASTER_PKGBASE:-0}" = 0 ] || stage_pkg_install FreeBSD-pam
	stage_exec pkg install -y sqlite3 gitea
}

stage_exec_as_git() { jexec -U git stage "$@"; }
echo_stage_exec_as_git() { echo_do jexec -U git stage "$@"; }
configure_gitea()
{
	tell_status "configuring Gitea"
	echo_stage_exec pw usermod git -d /home/git -m
	echo_stage_exec_as_git git config --global core.autocrlf input
	echo_stage_exec_as_git git config --global gc.auto 0
	echo_stage_exec_as_git git config --global repack.writeBitmaps true
	echo_stage_exec_as_git mkdir -p /home/git/.ssh

	echo_stage_exec sed -i '' \
		-e '/^APP_NAME / s/Gitea: Git with a cup of tea$/'"$(sed_replacement_quote "$GITEA_BRANDING")"'/' \
		-e '/^DOMAIN / s/localhost$/'"$GITEA_DOMAIN"'/' \
		-e '/^ROOT_URL / s,http://localhost:3000/,https://'"$GITEA_DOMAIN"'/,' \
		-e '/^SSH_PORT / s/22$/'"$GITEA_SSH_PORT"'/' \
		-e '/^DISABLE_REGISTRATION / s/false$/'"$GITEA_DISABLE_REGISTRATION"'/' \
		-e '/^SECRET_KEY / s/ChangeMeBeforeRunning/'"$GITEA_SECRET_KEY"'/' \
		-e '/^INTERNAL_TOKEN / s/ = .*$/ = '"$(sed_replacement_quote "$(stage_exec gitea generate secret INTERNAL_TOKEN)")"'/' \
		-e '/^\[mailer]/,/^$/ s/^ENABLED = false$/ENABLED = true/' \
		-e '/^REGISTER_EMAIL_CONFIRM / s/false$/true/' \
		-e '/^REQUIRE_SIGNIN_VIEW / s/false$/true/' \
		-e '/^ENABLE_NOTIFY_MAIL / s/false$/true/' \
		-e '/^\[database]$/a\
SQLITE_JOURNAL_MODE = WAL' \
		-e '/^\[log]$/a\
logger.xorm.MODE = \
logger.router.MODE = file' \
		-e '/^\[mailer]$/a\
PROTOCOL = smtp\
SMTP_ADDR = '"$TOASTER_MSA"'\
SMTP_PORT = 25\
FROM = '"$GITEA_FROM"'\
USER = '"$GITEA_SMTP_USER@${TOASTER_MAIL_DOMAIN}"'\
PASSWD = `'"$GITEA_SMTP_PASS"'`' \
                -e '/^\[server]$/a\
START_SSH_SERVER = true\
SSH_LISTEN_PORT = '"$GITEA_SSH_PORT" \
		-e '$a\
[admin]\
DISABLE_REGULAR_ORG_CREATION = true\
[attachment]\
MAX_SIZE = '"$GITEA_ATTACHMENT_SIZE_MB"'\
[cors]\
ENABLED = true\
[cron]\
ENABLED = true\
[email.incoming]\
ENABLED = true\
REPLY_TO_ADDRESS = '"$GITEA_SMTP_USER+%{token}@$TOASTER_MAIL_DOMAIN"'\
HOST = '"$(get_jail_ip dovecot)"'\
PORT = 143\
USERNAME = '"$GITEA_SMTP_USER@${TOASTER_MAIL_DOMAIN}"'\
PASSWORD = '"$GITEA_SMTP_PASS"'\
[log.console]\
STDERR = true\
[log.file]\
DAILY_ROTATE = false\
COMPRESS = false\
[ui.meta]\
AUTHOR = '"$GITEA_BRANDING"'\
DESCRIPTION = '"$GITEA_BRANDING" \
		"$_product_conf"
	echo_stage_exec chown git "$_product_conf"

	echo_stage_exec_as_git $_product_cmd doctor check --log-file - || { echo "doctor check returned $?" 1>&2; exit 1; }
	echo_stage_exec_as_git $_product_cmd migrate || { echo "migrate returned $?" 1>&2; exit 1; }

	echo_stage_exec_as_git $_product_cmd admin user list --admin

	stage_exec_as_git $_product_cmd admin user list --admin | grep -qvE '^([0-9]|ID)' \
	|| echo_stage_exec_as_git $_product_cmd admin user create \
		--admin \
		--username "$GITEA_ADMIN_USERNAME" \
		--password "$GITEA_ADMIN_PASSWORD" \
		--email "$GITEA_ADMIN_EMAIL" \
		--must-change-password false \
	|| echo "WARNING: could not create admin user?" 1>&2

	stage_sysrc gitea_enable=YES

	configure_ssh_pf_rdr gitea "$GITEA_SSH_PORT"
}

start_gitea()
{
	tell_status "starting up Gitea"
	stage_exec service gitea start
}

test_gitea()
{
	tell_status "testing Gitea"

	sleep 3 && echo_stage_exec_as_git $_product_cmd manager processes
	echo "it worked"
}

tell_settings GITEA
base_snapshot_exists || exit 1
create_staged_fs gitea
start_staged_jail gitea
install_gitea
configure_gitea
start_gitea
test_gitea
promote_staged_jail gitea
