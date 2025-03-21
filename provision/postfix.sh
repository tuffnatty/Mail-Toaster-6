#!/bin/sh

set -e -u

. mail-toaster.sh

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA=""
export JAIL_FSTAB="$ZFS_DATA_MNT/$TOASTER_MAILDIR $ZFS_JAIL_MNT/postfix/data/$TOASTER_MAILDIR nullfs rw,nosuid 0 2"

mt6-include mysql

_make_mysql_map()
{
	local _conf_dir="$STAGE_MNT/data/etc"
	local _name="$1"
	local _conninfo="$2"
	local _query="$3"
	store_config "$_conf_dir/$_name.cf" "overwrite" <<EO_ALIAS_MAPS
$_conninfo
query = $_query
EO_ALIAS_MAPS
}

install_postfix_mysql()
{
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

install_postfix()
{
	echo_stage_exec mkdir -p /data/$TOASTER_MAILDIR

	tell_status "Redirecting /var/spool/postfix to /data/spool"
	echo_stage_exec mkdir -p /data/spool
	echo_stage_exec chown root:wheel /data/spool
	echo_stage_exec chmod 0755 /data/spool
	echo_stage_exec ln -s /data/spool /var/spool/postfix

	local _rt_deps=""
	if [ "${TOASTER_PKGBASE:-0}" != 0 ]; then
		_rt_deps="
			FreeBSD-libexecinfo
			FreeBSD-sendmail"
		if [ "$(freebsd_major "$STAGE_MNT")" -ge 15 ]; then
			_rt_deps="$_rt_deps
				FreeBSD-audit
				FreeBSD-zlib
			"
		fi
	fi
	tell_status "installing postfix runtime dependencies"
	stage_pkg_install opendkim postfix-mysql $_rt_deps
	echo_stage_exec install -m 0644 /usr/local/share/postfix/mailer.conf.postfix /usr/local/etc/mail/mailer.conf

	if [ -n "$TOASTER_NRPE" ]; then
		tell_status "installing nagios-plugins"
		stage_pkg_install nrpe nagios-plugins
	fi
}

make_selector() { date '+%b%Y' | tr '[:upper:]' '[:lower:]'; }

configure_opendkim()
{
	stage_sysrc milteropendkim_enable=YES
	stage_sysrc milteropendkim_cfgfile=/data/etc/opendkim.conf

	tell_status "See http://www.opendkim.org/opendkim-README"

	local _dkim_dir="/data/dkim"
	local _selector

	if [ ! -d "$STAGE_MNT$_dkim_dir" ]; then mkdir "$STAGE_MNT$_dkim_dir"; fi

	local _opendkim_keyfile="$_dkim_dir/$TOASTER_MAIL_DOMAIN.private"
	if [ ! -f "$STAGE_MNT$_opendkim_keyfile" ]; then
		_selector="$(make_selector)"
		echo_stage_exec opendkim-genkey -b 2048 -h sha256 -D "$_dkim_dir" -s "$_selector" -v -d "$TOASTER_MAIL_DOMAIN"
		echo_stage_exec mv "$_dkim_dir/$_selector.private" "$_opendkim_keyfile"
		tell_status "Please add this TXT record: $(cat "$STAGE_MNT$_dkim_dir/$_selector.txt")"
	fi

	if [ -f "$STAGE_MNT/data/etc/opendkim.conf" ]; then
		tell_status "preserving opendkim config"
	else
		local _selector
		_selector="$(date '+%b%Y' | tr '[:upper:]' '[:lower:]')"
		tell_status "configuring opendkim"
		[ -n "$_selector" ] || _selector="$(make_selector)"

		# generate multi-domain ready config for easier customization
		store_config "$STAGE_MNT$_dkim_dir/KeyTable" "append" <<EO_KEY_TABLE
$_selector._domainkey.$TOASTER_MAIL_DOMAIN $TOASTER_MAIL_DOMAIN:$_selector:$_opendkim_keyfile
EO_KEY_TABLE
		store_config "$STAGE_MNT$_dkim_dir/SigningTable" "append" <<EO_SIGNING_TABLE
*@$TOASTER_MAIL_DOMAIN $_selector._domainkey.$TOASTER_MAIL_DOMAIN
EO_SIGNING_TABLE
		store_config "$STAGE_MNT$_dkim_dir/TrustedHosts" <<EO_TRUSTED_HOSTS
127.0.0.1
::1
$TOASTER_MAIL_DOMAIN
EO_TRUSTED_HOSTS

		sed \
			-e '/^Socket/ s/inet:port@localhost/inet:8891/' \
			-e "/^Domain/ s/^/#/" \
			-e "/^KeyFile/ s/^/#/" \
			-e "/^Selector/ s/^/#/" \
			-e "/^# ExternalIgnoreList/ s|^.*$|ExternalIgnoreList refile:$_dkim_dir/TrustedHosts|" \
			-e "/^# InternalHosts/ s|^.*$|InternalHosts refile:$_dkim_dir/TrustedHosts|" \
			-e "/^# KeyTable/ s|^.*$|KeyTable refile:$_dkim_dir/KeyTable|" \
			-e "/^# SigningTable/ s|^.*$|SigningTable refile:$_dkim_dir/SigningTable|" \
			"$STAGE_MNT/usr/local/etc/mail/opendkim.conf.sample" \
			| store_config "$STAGE_MNT/data/etc/opendkim.conf"
	fi
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

configure_postfix_main_cf()
{
	local _main_cf="$ZFS_DATA_MNT/postfix/etc/main.cf"
	if [ -f "$_main_cf" ]; then
		tell_status "preserving $_main_cf"
		return
	fi

	stage_exec install -m 0644 /usr/local/etc/postfix/main.cf /data/etc/main.cf

	local _postconfdir="/data/etc"
	export MAIL_CONFIG="$_postconfdir"
	if [ "$TOASTER_MSA" = "postfix" ]; then
		stage_exec postconf -e "myhostname = $TOASTER_HOSTNAME_SMTP"
	else
	stage_exec postconf -e "myhostname = postfix.$TOASTER_HOSTNAME"
	fi
	stage_exec postconf -e "myorigin = $TOASTER_MAIL_DOMAIN"

	local _ssldir="/data/etc/ssl"
	stage_exec postconf -e "smtpd_tls_cert_file = $_ssldir/certs/$TOASTER_MAIL_DOMAIN.pem"
	stage_exec postconf -e "smtpd_tls_key_file = $_ssldir/private/$TOASTER_MAIL_DOMAIN.pem"
	stage_exec postconf -e 'smtp_tls_security_level = may'
	stage_exec postconf -e 'smtpd_tls_security_level = may'
	stage_exec postconf -e 'smtpd_tls_auth_only = yes'
	stage_exec postconf -e 'lmtp_tls_security_level = may'
	stage_exec postconf -e "mynetworks = ${JAIL_NET_PREFIX}.0${JAIL_NET_MASK} ${POSTFIX_ADD_MYNETWORKS}"

	stage_exec postconf -e "virtual_mailbox_domains = proxy:mysql:$_postconfdir/virtual_domain_maps.cf"
	stage_exec postconf -e "virtual_alias_maps = proxy:mysql:$_postconfdir/virtual_alias_maps.cf, proxy:mysql:$_postconfdir/virtual_alias_domain_maps.cf, proxy:mysql:$_postconfdir/virtual_alias_domain_catchall_maps.cf"
	stage_exec postconf -e "virtual_mailbox_maps = proxy:mysql:$_postconfdir/virtual_mailbox_maps.cf, proxy:mysql:$_postconfdir/virtual_alias_domain_mailbox_maps.cf"
	stage_exec postconf -e "virtual_mailbox_base = /data/$TOASTER_MAILDIR"
	stage_exec postconf -e "virtual_uid_maps = static:$POSTFIX_MAILBOX_OWNER_UID"
	stage_exec postconf -e "virtual_gid_maps = static:$POSTFIX_MAILBOX_OWNER_GID"
	stage_exec postconf -e "message_size_limit = $(( ROUNDCUBE_ATTACHMENT_SIZE_MB * 1024 * 1024 * 137 / 100 ))"
	stage_exec postconf -e "mailbox_size_limit = $(( TOASTER_MAILBOX_SIZE_LIMIT_MB * 1024 * 1024 ))"
	stage_exec postconf -e "virtual_mailbox_limit = $(( TOASTER_MAILBOX_SIZE_LIMIT_MB * 1024 * 1024 ))"

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

	if [ -f "$ZFS_DATA_MNT/postfix/etc/transport" ]; then
		stage_exec postmap /data/etc/transport
		stage_exec postconf -e 'transport_maps = hash:/data/etc/transport'
	else
		stage_exec postconf -e "virtual_transport = lmtp:dovecot:24"
	fi

	if [ "$TOASTER_PLUS_ADDRESSING" = "1" ]; then
		stage_exec postconf -e 'recipient_delimiter = +'
	fi

	if [ -f "$_dkim_private_key" ]; then
		stage_exec postconf -e 'milter_default_action = accept'
		stage_exec postconf -e 'smtpd_milters = inet:localhost:8891'
		stage_exec postconf -e 'non_smtpd_milters = $smtpd_milters'
	fi
}

configure_postfix_master_cf()
{
	local _master_cf="$ZFS_DATA_MNT/postfix/etc/master.cf"
	if [ -f "$_master_cf" ]; then
		tell_status "preserving $_master_cf"
	else
		tell_status "installing $_master_cf"
		stage_exec install -m 0644 /usr/local/etc/postfix/master.cf /data/etc/master.cf
		export MAIL_CONFIG="/data/etc"
		# configure smtps (port 465)
		stage_exec postconf -M smtps/inet="smtps     inet  n       -       -       -       -       smtpd"
		stage_exec postconf -P "smtps/inet/syslog_name=postfix/smtps"
		stage_exec postconf -P "smtps/inet/smtpd_tls_security_level=encrypt"
		stage_exec postconf -P "smtps/inet/smtpd_tls_wrappermode=yes"
		stage_exec postconf -P "smtps/inet/smtpd_sasl_auth_enable=yes"
		stage_exec postconf -P "smtps/inet/smtpd_client_restrictions=permit_mynetworks,permit_sasl_authenticated,reject"
	fi
}

configure_postfix()
{
	stage_sysrc sendmail_enable=NONE
	stage_sysrc postfix_enable=YES
	stage_sysrc postfix_flags="-c /data/etc"

	if [ -e "$ZFS_DATA_MNT/spool" ]; then
		stage_sysrc postfix_pidfile=/data/spool/pid/master.pid
	fi

	configure_postfix_main_cf
	configure_postfix_master_cf

	# postconf will break symlinks to files. To get all of postfix to always
	# look at /data/etc for config, symlink the config dir
	echo_stage_exec mv /usr/local/etc/postfix /usr/local/etc/postfix.dist
	echo_stage_exec ln -s /data/etc /usr/local/etc/postfix

	if [ -n "$TOASTER_NRPE" ]; then
		stage_sysrc nrpe_enable=YES
		stage_sysrc nrpe_configfile="/data/etc/nrpe.cfg"
	fi

	configure_tls_certs

	configure_opendkim

	preserve_file postfix '/etc/mail/aliases'
	stage_exec /usr/local/sbin/postalias /etc/mail/aliases

	stage_exec install -m 0644 /usr/local/share/postfix/mailer.conf.postfix /data/etc/mailer.conf

	_pf_etc="$(get_jail_etc postfix)/pf.conf.d"
	store_config "$_pf_etc/rdr.conf" <<EO_PF
rdr pass inet  proto tcp from any to <ext_ip4> port { 25 465 587 } -> $(get_jail_ip  postfix)
rdr pass inet6 proto tcp from any to <ext_ip6> port { 25 465 587 } -> $(get_jail_ip6 postfix)
EO_PF
}

start_postfix()
{
	tell_status "starting postfix"
	if [ -f "$_dkim_private_key" ]; then
		stage_exec service milter-opendkim start
	fi
	if [ -f "$ZFS_DATA_MNT/postfix/spool/pid/master.pid" ]; then
		jexec postfix service postfix stop
	fi
	stage_exec service postfix start
}

test_postfix()
{
	if [ -f "$_dkim_private_key" ]; then
		tell_status "testing opendkim"
		stage_test_running opendkim
		stage_listening 8891
	fi

	tell_status "testing postfix"
	stage_test_running master
	stage_listening 25
	echo "it worked."
}

base_snapshot_exists || exit 1
create_staged_fs postfix
start_staged_jail postfix
install_postfix
install_postfix_mysql
configure_postfix
start_postfix
test_postfix
promote_staged_jail postfix
