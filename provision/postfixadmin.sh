#!/bin/sh
set -e

. mail-toaster.sh || exit

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA=""

mt6-include php
mt6-include nginx
mt6-include mysql

pa_php_ver=81

mysql_error_warning()
{
    echo; echo "-----------------"
    echo "WARNING: could not connect to MySQL. (Is it password protected?) If"
    echo "this is a new install, manually set up MySQL for postfixadmin."
    echo "-----------------"; echo
    sleep 5
}

install_postfixadmin_mysql()
{
	set -e
	assure_jail mysql

	local _init_db=1
	if ! mysql_db_exists postfix_db; then
		tell_status "creating postfix mysql db"
		mysql_create_db postfix_db || mysql_error_warning

		if mysql_db_exists postfix_db; then
			_init_db=1
		fi
	fi

	if [ "$_init_db" = "1" ]; then
		tell_status "configuring postfix mysql permissions"

		for _jail in dovecot postfix stage postfixadmin; do
			for _ip in $(get_jail_ip "$_jail") $(get_jail_ip6 "$_jail");
			do
				echo "GRANT ALL PRIVILEGES ON postfix_db.* TO 'postfix_user'@'${_ip}' IDENTIFIED BY '$TOASTER_MYSQL_PASS';" \
					| mysql_query || exit
			done
		done

		postfixadmin_init_db
	fi
}

postfixadmin_init_db()
{
	tell_status "Go to postfixadmin start page for initial db migration"
	pkg install -y curl

	start_postfixadmin
	curl -i "http://$(get_jail_ip stage)/setup.php"
	#stage_exec postfixadmin-cli admin add "$TOASTER_ADMIN_EMAIL" --superadmin 1 --active 1 --password "$TOASTER_ADMIN_PASS" --password2 "$TOASTER_ADMIN_PASS"
	stage_exec postfixadmin-cli domain add "$TOASTER_MAIL_DOMAIN" || echo "$(red)WARNING: could not add domain$(normal)"
}

install_postfixadmin()
{
	set -e
	install_php "$pa_php_ver" "imap" || exit
	install_nginx || exit

	tell_status "installing postfixadmin"
	stage_pkg_install "postfixadmin33-php$pa_php_ver"
	postfixadmin_root="/usr/local/www/postfixadmin33"

	tell_status "installing postfixadmin-cli"
	stage_exec chmod a+x $postfixadmin_root/scripts/postfixadmin-cli
	stage_exec ln -s $postfixadmin_root/scripts/postfixadmin-cli /usr/local/bin/postfixadmin-cli

	tell_status "installing dovecot (only for doveadm pw)"
	stage_pkg_install dovecot
}

configure_nginx_server()
{
	local _datadir="$ZFS_DATA_MNT/postfixadmin"
	if [ -f "$_datadir/etc/nginx-server.conf" ]; then
		tell_status "preserving /data/etc/nginx-server.conf"
		return
	fi

	tell_status "saving /data/etc/nginx-locations.conf"
	tee "$_datadir/etc/nginx-locations.conf" <<EO_NGINX_LOCALS

	server_name  postfixadmin;
	root   $postfixadmin_root/public;
	index  index.php;

	location / {
		try_files \$uri \$uri/ /index.php;
	}

	location /postfixadmin {
		alias $postfixadmin_root/public;
	}

	location ~ \\.php\$ {
		include        /usr/local/etc/nginx/fastcgi_params;
		fastcgi_index  index.php;
		fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
		fastcgi_pass   php;
	}
EO_NGINX_LOCALS
}

configure_postfixadmin()
{
	configure_php postfixadmin

	tell_status "installing mime.types"
	fetch -o "$STAGE_MNT/usr/local/etc/mime.types" \
		http://svn.apache.org/repos/asf/httpd/httpd/trunk/docs/conf/mime.types

	configure_nginx postfixadmin
	configure_nginx_server

	tell_status "configuring dovecot so that doveadm pw is working"
	cp -a "$STAGE_MNT/usr/local/etc/dovecot/example-config"/* "$STAGE_MNT/usr/local/etc/dovecot/"
	echo "ssl = no" > "$STAGE_MNT/usr/local/etc/dovecot/conf.d/10-ssl.conf"

	local _local_path="$postfixadmin_root/config.inc.php"
	local _local_local_path="$postfixadmin_root/config.local.php"
	local _pa_conf="$STAGE_MNT/$_local_path"
	local _pa_local_conf="$STAGE_MNT/$_local_local_path"
	#if [ -f "$ZFS_JAIL_MNT/postfixadmin.last/$_local_path.bak" ]; then
	#	tell_status "preserving $_pa_conf"
	#	cp "$ZFS_JAIL_MNT/postfixadmin.last/$_local_path" "$_pa_conf" || exit
	#	return
	#fi

	tell_status "customizing $_pa_conf"
	local _pa_pass _pa_hashed_pass _pa_salt
	_pa_pass="$(openssl rand -hex 18)"
	_pa_hashed_pass="$(stage_exec php -r "var_export(password_hash('$_pa_pass', PASSWORD_DEFAULT));")"
	tell_status "generated postfixadmin setup password is $_pa_pass"

	local _pa_admin_url
	_pa_admin_url="http://$(get_jail_ip postfixadmin)/postfixadmin"

	sed \
		-e "/^\\\$CONF\\['configured'/		s/false/true/" \
		-e "/^\\\$CONF\\['database_host'/	s/localhost/$(get_jail_ip mysql)/" \
		-e "/^\\\$CONF\\['database_user'/	s/postfix/postfix_user/" \
		-e "/^\\\$CONF\\['database_password'/	s/postfixadmin/$(sed_replacement_quote "$TOASTER_MYSQL_PASS")/" \
		-e "/^\\\$CONF\\['database_name'/	s/postfix/postfix_db/" \
		-e "/^\\\$CONF\\['setup_password'/	s/'changeme'/$(sed_replacement_quote "$_pa_hashed_pass")/" \
		-e "/^\\\$CONF\\['vacation'/		s/YES/NO/" \
		-e "/^\\\$CONF\\['domain_path'/		s/NO/YES/" \
		-e "/^\\\$CONF\\['domain_in_mailbox'/	s/YES/NO/" \
		-e "/^\\\$CONF\\['aliases'/		s/10/0/" \
		-e "/^\\\$CONF\\['mailboxes'/		s/10/0/" \
		-e "/^\\\$CONF\\['maxquota'/		s/10/0/" \
		-e "/^\\\$CONF\\['site_url'/		s,null,'$_pa_admin_url'," \
		-e "/^\\\$CONF\\['smtp_server'/		s/localhost/$TOASTER_MSA/" \
		-e "/^\\\$CONF\\['encrypt'/             s/'md5crypt'/'dovecot:SHA512-CRYPT'/" \
		-e "/^\\\$CONF\\['dovecotpw'/		s,/usr/local/sbin/dovecotpw,/usr/local/bin/doveadm pw," \
		-e "/^\\\$CONF\\['admin_email'/		s/''/'postmaster@$TOASTER_MAIL_DOMAIN'/" \
		-e "s/change-this-to-your.domain.tld/$TOASTER_MAIL_DOMAIN/g" \
		"$_pa_conf" > "$_pa_local_conf" || exit 1

	install_postfixadmin_mysql
}

start_postfixadmin()
{
	start_php_fpm
	start_nginx
}

test_postfixadmin()
{
	test_php_fpm
	test_nginx
	echo "it worked"
}

base_snapshot_exists || exit
create_staged_fs postfixadmin
start_staged_jail postfixadmin
install_postfixadmin
configure_postfixadmin
start_postfixadmin
test_postfixadmin
promote_staged_jail postfixadmin
