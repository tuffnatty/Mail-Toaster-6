#!/bin/sh
set -e

. mail-toaster.sh || exit

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA="
		mount += \"$ZFS_DATA_MNT/postfix \$path/data nullfs rw 0 1\";
		mount += \"$ZFS_DATA_MNT/$TOASTER_MAILDIR \$path/data/$TOASTER_MAILDIR nullfs rw 0 2\";"

mt6-include mysql

mysql_error_warning()
{
    echo; echo "-----------------"
    echo "WARNING: could not connect to MySQL. (Is it password protected?) If"
    echo "this is a new install, manually set up MySQL for postfix."
    echo "-----------------"; echo
    sleep 5
}

_make_mysql_map()
{
	local _conf_dir="$STAGE_MNT/usr/local/etc/postfix"
	local _name="$1"
	local _conninfo="$2"
	local _query="$3"
	tee "$_conf_dir/$_name.cf" <<EO_ALIAS_MAPS
$_conninfo
query = $_query
EO_ALIAS_MAPS
}

install_postfix_mysql()
{
	set -e
	assure_jail mysql

	if ! mysql_db_exists postfix_db; then
		tell_status "postfix_db database does not exist, provision postfixadmin first"
		exit 1
	fi

	local _conninfo
	_conninfo="user = postfix_user
password = $TOASTER_MYSQL_PASS
hosts = $(get_jail_ip mysql)
dbname = postfix_db"

	_make_mysql_map "virtual_alias_domain_catchall_maps" "$_conninfo" \
            "SELECT goto FROM alias,alias_domain WHERE alias_domain.alias_domain = '%d' and alias.address = CONCAT('@', alias_domain.target_domain) AND alias.active = 1 AND alias_domain.active='1'"
	_make_mysql_map "virtual_alias_domain_mailbox_maps" "$_conninfo" \
	    "SELECT maildir FROM mailbox,alias_domain WHERE alias_domain.alias_domain = '%d' and mailbox.username = CONCAT('%u', '@', alias_domain.target_domain) AND mailbox.active = 1 AND alias_domain.active='1'"
	_make_mysql_map "virtual_alias_domain_maps" "$_conninfo" \
	    "SELECT goto FROM alias,alias_domain WHERE alias_domain.alias_domain = '%d' and alias.address = CONCAT('%u', '@', alias_domain.target_domain) AND alias.active = 1 AND alias_domain.active='1'"
	_make_mysql_map "virtual_alias_maps" "$_conninfo" \
	    "SELECT goto FROM alias WHERE address='%s' AND active = '1'"
	_make_mysql_map "virtual_domain_maps" "$_conninfo" \
	    "SELECT domain FROM domain WHERE domain='%s' AND active = '1'"
	_make_mysql_map "virtual_mailbox_maps" "$_conninfo" \
	    "SELECT maildir FROM mailbox WHERE username='%s' AND active = '1'"
}


_dkim_private_key="$ZFS_DATA_MNT/postfix/dkim/$TOASTER_MAIL_DOMAIN.private"
_has_dkim=""
if [ -f "$_dkim_private_key" ]; then _has_dkim=1; fi

install_postfix()
{
	echo_stage_exec mkdir -p /data/$TOASTER_MAILDIR

	tell_status "Redirecting /var/spool/postfix to /data/spool"
	stage_exec mkdir -p /data/spool
	stage_exec chown root:wheel /data/spool
	stage_exec chmod 0755 /data/spool
	stage_exec ln -s /data/spool /var/spool/postfix

	tell_status "installing postfix"
	stage_pkg_install postfix mysql57-client opendkim dialog4ports || exit

	tell_status "configure postfix port options"
	stage_make_conf postfix_SET 'mail_postfix_SET=MYSQL'
	stage_make_conf MAKE_JOBS_NUMBER "MAKE_JOBS_NUMBER=$(sysctl -n hw.ncpu)"

	tell_status "building postfix"
	stage_pkg_install dialog4ports

	export BATCH=${BATCH:="1"}
	stage_port_install mail/postfix || exit 1

	if [ -n "$TOASTER_NRPE" ]; then
		tell_status "installing nagios-plugins"
		stage_pkg_install nagios-plugins || exit
	fi
}

configure_opendkim()
{
	stage_sysrc milteropendkim_enable=YES
	stage_sysrc milteropendkim_cfgfile=/data/etc/opendkim.conf

	tell_status "See http://www.opendkim.org/opendkim-README"

	local _dkim_dir="/data/dkim"
	local _selector

	echo_stage_exec mkdir -p /data/etc "$_dkim_dir"

	local _opendkim_keyfile="$_dkim_dir/$TOASTER_MAIL_DOMAIN.private"
	if [ ! -f "$STAGE_MNT$_opendkim_keyfile" ]; then
		_selector="$(date '+%b%Y' | tr '[:upper:]' '[:lower:]')"
		echo_stage_exec opendkim-genkey -b 2048 -h sha256 -D "$_dkim_dir" -s "$_selector" -v -d "$TOASTER_MAIL_DOMAIN"
		echo_stage_exec mv "$_dkim_dir/$_selector.private" "$_opendkim_keyfile"
		tell_status "Add TXT record: $(cat "$STAGE_MNT$_dkim_dir/$_selector.txt")"
	fi
	if [ -f "$STAGE_MNT/data/etc/opendkim.conf" ]; then
		echo "opendkim config retained"
	else
		[ -n "$_selector" ] || _selector="$(date '+%b%Y' | tr '[:upper:]' '[:lower:]')"
		sed \
			-e "/^Domain/ s/example.com/$TOASTER_MAIL_DOMAIN/"  \
			-e "/^KeyFile/ s,/.*\$,$_opendkim_keyfile,"  \
			-e '/^Socket/ s/inet:port@localhost/inet:2016/' \
			-e "/^Selector/ s/my-selector-name/$_selector/" \
			"$STAGE_MNT/usr/local/etc/mail/opendkim.conf.sample" \
			> "$STAGE_MNT/data/etc/opendkim.conf"
	fi

	stage_exec postconf -e 'milter_default_action = accept'
	stage_exec postconf -e 'smtpd_milters = inet:localhost:2016'
	stage_exec postconf -e 'non_smtpd_milters = $smtpd_milters'
}

configure_tls_certs()
{
	local _ssldir="$ZFS_DATA_MNT/postfix/etc/ssl"
	if [ ! -d "$_ssldir/certs" ]; then
		mkdir -p "$_ssldir/certs" || exit
		chmod 644 "$_ssldir/certs" || exit
	fi

	if [ ! -d "$_ssldir/private" ]; then
		mkdir "$_ssldir/private" || exit
		chmod 644 "$_ssldir/private" || exit
	fi

	local _installed_crt="$_ssldir/certs/${TOASTER_MAIL_DOMAIN}.pem"
	if [ -f "$_installed_crt" ]; then
		tell_status "postfix TLS certificates already installed"
		return
	fi

	tell_status "installing postfix TLS certificates"
	cp /etc/ssl/certs/server.crt "$_ssldir/certs/${TOASTER_MAIL_DOMAIN}.pem" || exit
	cp /etc/ssl/private/server.key "$_ssldir/private/${TOASTER_MAIL_DOMAIN}.pem" || exit
}

configure_postfix()
{
	local _postconfdir="/usr/local/etc/postfix"
	stage_sysrc postfix_enable=YES
	if [ "$TOASTER_MSA" = "postfix" ]; then
		stage_exec postconf -e "myhostname = $TOASTER_HOSTNAME_SMTP"
	else
		stage_exec postconf -e "myhostname = postfix.$TOASTER_HOSTNAME"
	fi
	stage_exec postconf -e "myorigin = $TOASTER_MAIL_DOMAIN"
	stage_exec postconf -e 'smtp_use_tls=yes'
	stage_exec postconf -e 'smtp_tls_security_level = may'
	stage_exec postconf -e "mynetworks = ${JAIL_NET_PREFIX}.0${JAIL_NET_MASK} ${POSTFIX_ADD_MYNETWORKS}"

	local _ssldir="/data/etc/ssl"
	stage_exec postconf -e "smtpd_tls_cert_file = $_ssldir/certs/$TOASTER_MAIL_DOMAIN.pem"
	stage_exec postconf -e "smtpd_tls_key_file = $_ssldir/private/$TOASTER_MAIL_DOMAIN.pem"
	stage_exec postconf -e 'smtpd_use_tls = yes'
	stage_exec postconf -e 'smtpd_tls_security_level = may'
	stage_exec postconf -e "virtual_mailbox_domains = proxy:mysql:$_postconfdir/virtual_domain_maps.cf"
	stage_exec postconf -e "virtual_alias_maps = proxy:mysql:$_postconfdir/virtual_alias_maps.cf, proxy:mysql:$_postconfdir/virtual_alias_domain_maps.cf, proxy:mysql:$_postconfdir/virtual_alias_domain_catchall_maps.cf"
	stage_exec postconf -e "virtual_mailbox_maps = proxy:mysql:$_postconfdir/virtual_mailbox_maps.cf, proxy:mysql:$_postconfdir/virtual_alias_domain_mailbox_maps.cf"
	stage_exec postconf -e "virtual_mailbox_base = /data/$TOASTER_MAILDIR"
	stage_exec postconf -e "virtual_uid_maps = static:$POSTFIX_MAILBOX_OWNER_UID"
	stage_exec postconf -e "virtual_gid_maps = static:$POSTFIX_MAILBOX_OWNER_GID"
	stage_exec postconf -e "message_size_limit = $(( ROUNDCUBE_ATTACHMENT_SIZE_MB * 1024 * 1024 * 137 / 100 ))"
	stage_exec postconf -e "mailbox_size_limit = $(( TOASTER_MAILBOX_SIZE_LIMIT_MB * 1024 * 1024 ))"
	stage_exec postconf -e "virtual_mailbox_limit = $(( TOASTER_MAILBOX_SIZE_LIMIT_MB * 1024 * 1024 ))"

	stage_exec postconf -e "virtual_transport = lmtp:dovecot:24"

	if [ -f "$ZFS_DATA_MNT/postfix/etc/sasl_passwd" ]; then
		stage_exec postmap /data/etc/sasl_passwd
		stage_exec postconf -e 'smtp_sasl_auth_enable = yes'
		stage_exec postconf -e 'smtp_sasl_password_maps = hash:/data/etc/sasl_passwd'
	else
		stage_exec postconf -e 'smtpd_sasl_type = dovecot'
		stage_exec postconf -e "smtpd_sasl_path = inet:$(get_jail_ip dovecot):$DOVECOT_AUTH_LISTENER_TCP_PORT"
		stage_exec postconf -e 'broken_sasl_auth_clients = yes'
		stage_exec postconf -e 'smtpd_sasl_auth_enable = yes'
		stage_exec postconf -e 'smtpd_sasl_local_domain ='
		#stage_exec postconf -e 'smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_rbl_client zen.spamhaus.org, reject_rbl_client bl.spamcop.net, reject_unauth_destination'
		stage_exec postconf -e 'smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
	fi

	if [ "x$TOASTER_PLUS_ADDRESSING" = "x1" ]; then
		stage_exec postconf -e 'recipient_delimiter = +'
	fi

	# configure smtps (port 465)
	stage_exec postconf -M smtps/inet="smtps     inet  n       -       -       -       -       smtpd"
	stage_exec postconf -P "smtps/inet/syslog_name=postfix/smtps"
	stage_exec postconf -P "smtps/inet/smtpd_tls_security_level=encrypt"
	stage_exec postconf -P "smtps/inet/smtpd_tls_wrappermode=yes"
	stage_exec postconf -P "smtps/inet/smtpd_sasl_auth_enable=yes"
	stage_exec postconf -P "smtps/inet/smtpd_client_restrictions=permit_mynetworks,permit_sasl_authenticated,reject"

	if [ -n "$TOASTER_NRPE" ]; then
		stage_sysrc nrpe3_enable=YES
		stage_sysrc nrpe3_configfile="/data/etc/nrpe.cfg"
	fi

	for _f in master main
	do
		if [ -f "$ZFS_DATA_MNT/postfix/etc/$_f.cf" ]; then
			tell_status "preserving /usr/local/etc/postfix/$_f.cf"
			cp "$ZFS_DATA_MNT/postfix/etc/$_f.cf" "$STAGE_MNT/usr/local/etc/postfix/"
		fi
	done

	configure_tls_certs

	if [ -f "$ZFS_JAIL_MNT/postfix/etc/aliases" ]; then
		tell_status "preserving /etc/aliases"
		cp "$ZFS_JAIL_MNT/postfix/etc/aliases" "$STAGE_MNT/etc/aliases"
		stage_exec newaliases
	fi

	if [ ! -f "$STAGE_MNT/usr/local/etc/mail/mailer.conf" ]; then
		if [ ! -d "$STAGE_MNT/usr/local/etc/mail" ]; then
			mkdir "$STAGE_MNT/usr/local/etc/mail"
		fi
		stage_exec install -m 0644 /usr/local/share/postfix/mailer.conf.postfix /usr/local/etc/mail/mailer.conf
	fi

	configure_opendkim
}

start_postfix()
{
	tell_status "starting postfix"
	if [ -n "$_has_dkim" ]; then
		stage_exec service milter-opendkim start
	fi
	mount_data "$TOASTER_MAILDIR"
	stage_exec service postfix start || exit
}

test_postfix()
{
	if [ -n "$_has_dkim" ]; then
		tell_status "testing opendkim"
		stage_test_running opendkim
		stage_listening 2016
	fi

	tell_status "testing postfix"
	stage_test_running master
	stage_listening 25
	echo "it worked."
}

base_snapshot_exists || exit
unmount_data "$TOASTER_MAILDIR"
create_staged_fs postfix
start_staged_jail postfix
install_postfix
install_postfix_mysql
configure_postfix
start_postfix
test_postfix
unmount_data "$TOASTER_MAILDIR"
TOASTER_PKG_AUDIT=0 promote_staged_jail postfix
