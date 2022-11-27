#!/bin/sh

postfixadmin_configure_dovecot_sql()
{
	[ -n "$TOASTER_MYSQL_PASS" ] || return
	store_config "$1" "overwrite" <<EO_DOVECOT_POSTFIXADMIN_SQL
  driver = mysql
  default_pass_scheme = DIGEST-MD5
  connect = host=mysql user=postfix_user password=$TOASTER_MYSQL_PASS dbname=postfix_db

  password_query = SELECT \\
    username AS user \\
    , password \\
    FROM mailbox \\
    WHERE username = '%u'
      AND active = 1

  user_query = SELECT \\
    CONCAT('/data/vmail/', maildir) AS home \\
    , $POSTFIX_MAILBOX_OWNER_UID AS uid \\
    , $POSTFIX_MAILBOX_OWNER_GID AS gid \\
    , CONCAT('*:bytes=', quota) AS quota_rule
    FROM mailbox
    WHERE username = '%u'
      AND active = 1
EO_DOVECOT_POSTFIXADMIN_SQL
}

postfixadmin_install_postfix_mysql_maps()
{
	local _conf_dir="$1"

	set -- \
		"virtual_alias_domain_catchall_maps" \
		"SELECT goto FROM alias, alias_domain
			WHERE alias_domain.alias_domain = '%d'
			AND alias.address = CONCAT('@', alias_domain.target_domain)
			AND alias.active = 1
			AND alias_domain.active = 1" \
		\
		"virtual_alias_domain_mailbox_maps" \
		"SELECT maildir FROM mailbox, alias_domain
			WHERE alias_domain.alias_domain = '%d'
			AND mailbox.username = CONCAT('%u', '@', alias_domain.target_domain)
			AND mailbox.active = 1
			AND alias_domain.active = 1" \
		\
		"virtual_alias_domain_maps" \
		"SELECT goto FROM alias, alias_domain
			WHERE alias_domain.alias_domain = '%d'
			AND alias.address = CONCAT('%u', '@', alias_domain.target_domain)
			AND alias.active = 1
			AND alias_domain.active = 1" \
		\
		"virtual_alias_maps" \
		"SELECT goto FROM alias
			WHERE address = '%s'
			AND active = 1" \
		\
		"virtual_domain_maps" \
		"SELECT domain FROM domain
			WHERE domain = '%s'
			AND active = 1" \
		\
		"virtual_mailbox_maps" \
		"SELECT maildir FROM mailbox
			WHERE username = '%s'
			AND active = 1"
	while [ $# -gt 0 ]; do
		store_config "$_conf_dir/$1.cf" "overwrite" <<EO_MAPS
user = postfix_user
password = ${TOASTER_MYSQL_PASS:?TOASTER_MYSQL_PASS must be set!}
hosts = $(get_jail_ip mysql)
dbname = postfix_db
query = $2
EO_MAPS
		shift 2
	done
}
