#!/bin/sh
# shellcheck disable=SC3040
set -e -u -o pipefail

. mail-toaster.sh
service_config webhost
export WEBHOST_ATTACHMENT_SIZE_MB=${WEBHOST_ATTACHMENT_SIZE_MB:-"25"}
export WEBHOST_DOCUMENT_INDEX="${WEBHOST_DOCUMENT_INDEX:-"index.php"}"
export WEBHOST_DOCUMENT_ROOT="${WEBHOST_DOCUMENT_ROOT:-"/data/www/public"}"
export WEBHOST_GID=${WEBHOST_GID:-""}
export WEBHOST_MYSQL_SERVER=${WEBHOST_MYSQL_SERVER:-"0"}
export WEBHOST_MYSQL_SERVER_PASSWORD=${WEBHOST_MYSQL_SERVER_PASSWORD:-""}
export WEBHOST_PHP_MEMORY_LIMIT_MB=${WEBHOST_PHP_MEMORY_LIMIT:-"128"}
export WEBHOST_PHP_MODULES=${WEBHOST_PHP_MODULES:-""}
export WEBHOST_SERVER_TYPE=${WEBHOST_SERVER_TYPE:-"nginx"}
export WEBHOST_SSH_PORT=${WEBHOST_SSH_PORT:-""}
export WEBHOST_UID=${WEBHOST_UID:-""}
export WEBHOST_USER=${WEBHOST_USER:-""}
export WEBHOST_USER_CRONTAB=${WEBHOST_USER_CRONTAB:-""}
export WEBHOST_USER_SUDO=${WEBHOST_USER_SUDO:-"0"}

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA=""
export JAIL_FSTAB=""

mt6-include php
mt6-include nginx
mt6-include mysql

_pw_jname="${webhost_name:=webhost01}"

case "$webhost_name" in
	password_changer) ;;
	webhost01)	 ;;
	*) echo "$(red)unknown host: $webhost_name" ;;
esac

create_webhost_user()
{
	[ -n "${WEBHOST_USER:-}" ] || return 0
	local _homedir="$ZFS_DATA_MNT/$_pw_jname/home"
	local _internal_homedir="/data/home"
	[ -d "$_homedir" ] || echo_do mkdir -p "$_homedir"
	echo_stage_exec pw groupadd -n "$WEBHOST_USER" -g "$WEBHOST_GID"
	if [ -n "${WEBHOST_USER_PASS:-}" ]; then
		printf '%s' "$WEBHOST_USER_PASS" | echo_stage_exec pw useradd -n "$WEBHOST_USER" -s /bin/sh -m -d "$_internal_homedir/$WEBHOST_USER" -u $WEBHOST_UID -g $WEBHOST_GID -H 0
	else
		echo_stage_exec pw useradd -n "$WEBHOST_USER" -s /bin/sh -m -d "$_internal_homedir/$WEBHOST_USER" -u $WEBHOST_UID -g $WEBHOST_GID -w random
	fi
	[ -z "$WEBHOST_USER_CRONTAB" ] || echo_stage_exec crontab -u $WEBHOST_USER - <<EOF
$WEBHOST_USER_CRONTAB
EOF

	if [ "${WEBHOST_USER_SUDO:-0}" = 1 ]; then
		stage_pkg_install sudo
		echo_stage_exec tee /usr/local/etc/sudoers.d/$_pw_jname <<-EOF
			$WEBHOST_USER ALL=(ALL:ALL) ALL
		EOF
	fi

	if [ -n "${WEBHOST_SSH_PORT:-}" ]; then
		stage_sysrc sshd_enable=YES sshd_flags="-p $WEBHOST_SSH_PORT"
	fi
}

install_webhost_mysql()
{
	[ "$WEBHOST_MYSQL_SERVER" = 1 ] || return 0

	tell_status "installing mariadb"
	stage_pkg_install mariadb114-server || exit

	configure_webhost_mysql
	start_webhost_mysql
	write_pass_to_conf
	test_webhost_mysql

	create_webhost_db
}

configure_webhost_mysql()
{
	local _mydir="$ZFS_DATA_MNT/$_pw_jname/mysql"
	tell_status "configuring mysql"
	#[ -d  "$_mydir" ] || { 
	#	echo_do mkdir -p "$_mydir"
	#	echo_do chown 88:88 "$_mydir"
	#	echo_stage_exec ln -sfh /data/mysql /var/db/mysql
	#}
	stage_sysrc mysql_args="--syslog --innodb-doublewrite=off --innodb-file-per-table=1 --innodb-data-home-dir=/data/mysql --innodb-log-group-home-dir=/data/mysql --max-binlog-size=512M --expire-logs-days=7 --tmpdir=/tmp/mysql --slow_query_log=1"
	stage_sysrc mysql_dbdir="/data/mysql"
	#stage_sysrc mysql_optfile="/data/mysql/my.cnf"

	tee -a $STAGE_MNT/etc/rc.local <<'EO_RC_LOCAL'
mkdir -p /tmp/mysql
chown mysql:mysql /tmp/mysql
EO_RC_LOCAL
	stage_exec service local start

	if [ -f "$ZFS_JAIL_MNT/$_pw_jname/etc/my.cnf" ]; then
		tell_status "$(red)preserving /etc/my.cnf"
		echo_do cp "$ZFS_JAIL_MNT/$_pw_jname/etc/my.cnf" "$STAGE_MNT/etc/my.cnf"
	fi

	stage_exec service mysql-server onestart
	stage_exec service mysql-server onestop

	local _dbdir="$ZFS_DATA_MNT/$_pw_jname/mysql"
#	if [ ! -d "$_dbdir" ]; then
#		mkdir -p "$_dbdir" || exit
#	fi
#
#	local _my_cnf="$_dbdir/my.cnf"
#	if [ ! -f "$_my_cnf" ]; then
#		tell_status "installing $_my_cnf"
#		tee -a "$_my_cnf" <<EO_MY_CNF
#[mysqld]
#innodb_doublewrite = off
#innodb_file_per_table = 1
#EO_MY_CNF
#	else
	if [ ! -d "$_dbdir" ]; then
		rm -f "$STAGE_MNT/root/.mysql_secret"
	fi

	if [ ! -f "$_dbdir/private_key.pem" ]; then
		tell_status "enabling sha256_password support"
		openssl genrsa -out "$_dbdir/private_key.pem" 2048
		chown 88:88 "$_dbdir/private_key.pem"
		chmod 400 "$_dbdir/private_key.pem"
	fi

	if [ ! -f "$_dbdir/public_key.pem" ]; then
		openssl rsa -in "$_dbdir/private_key.pem" -pubout -out "$_dbdir/public_key.pem"
		chown 88:88 "$_dbdir/public_key.pem"
		chmod 444 "$_dbdir/public_key.pem"
	fi
}

start_webhost_mysql()
{
	tell_status "starting mysql"
	stage_sysrc mysql_enable=YES

	if [ -d "$ZFS_JAIL_MNT/$_pw_jname/var/db/mysql/mysql" ]; then
		# webhost jail already exists, unmount the data dir since two mysql's
		# cannot access the data concurrently
		unmount_data $_pw_jname "$ZFS_JAIL_MNT/$_pw_jname"
	fi

	echo_stage_exec service mysql-server start || exit
}

test_webhost_mysql()
{
	if [ -f "$STAGE_MNT/root/.mysql_secret" ]; then
		tell_status "new install, setting root password"
		local _initial_pass
		_initial_pass=$(tail -n1 "$STAGE_MNT/root/.mysql_secret")
		if [ -z "$_initial_pass" ]; then
			echo "ERROR: unable to find the mysql initial password"
			exit 1
		fi
		echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '$WEBHOST_MYSQL_SERVER_PASSWORD';" \
			| stage_exec mysql -u root --connect-expired-password --password="$_initial_pass" \
			|| exit 1
		rm "$STAGE_MNT/root/.mysql_secret"
	fi

	if [ -d "$ZFS_DATA_MNT/$_pw_jname/mysql/mysql" ]; then
		tell_status "reinstall, skipping tests"
		return
	fi

	tell_status "testing mysql"

	echo 'SHOW DATABASES' | stage_exec mysql --password="$WEBHOST_MYSQL_SERVER_PASSWORD" || exit
	stage_listening 3306
	echo "it worked"
}

write_pass_to_conf()
{
	tee "$STAGE_MNT/root/.my.cnf" <<EO_MY_CNF
[client]
user = root
password = $WEBHOST_MYSQL_PASS
EO_MY_CNF
	chmod 600 "$STAGE_MNT/root/.my.cnf"
}

# shellcheck disable=SC2046
stage_mysql() { stage_exec $(mysql_bin) "$@"; }

stage_mysql_create_db()
{
	if stage_mysql_db_exists "$1"; then
		tell_status "db '$1' exists in mysql"
		return 0
	fi

	tell_status "creating mysql database $1"
	echo "CREATE DATABASE $1 CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" | stage_mysql || return 1
	return 0
}

stage_mysql_db_exists()
{
	local _query="SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$1';"
	local result
	# shellcheck disable=SC2046
	result=$(echo "$_query" | stage_mysql -s -N)
	if [ -z "$result" ]; then
		echo "$1 db does not exist"
		return 1
	fi

	echo "$1 db exists"
	return 0
}

stage_mysql_query()
{
	if [ -n "$1" ]; then
		echo "db: $1"
		stage_mysql "$1" || return 1
	else
		stage_mysql || return 1
	fi

	return 0
}

create_webhost_db()
{
	stage_pkg_install mariadb114-client

	local _init_db=0
	if ! stage_mysql_db_exists "$_pw_jname"; then
		tell_status "creating $_pw_jname mysql db"
		stage_mysql_create_db "$_pw_jname" || mysql_error_warning

		if stage_mysql_db_exists "$_pw_jname"; then
			_init_db=1
		fi
	fi

	local _datadir="$ZFS_DATA_MNT/$_pw_jname"
	local _iwp_dir="$_datadir"
	tee "$_iwp_dir/db.config" <<EOF
user: $_pw_jname
host: localhost
password: $WEBHOST_MYSQL_SERVER_PASSWORD
EOF

	if [ "$_init_db" = "1" ]; then
		tell_status "configuring $_pw_jname mysql permissions"

		for _jail in "$_pw_jname" stage; do
			for _ip in $(get_jail_ip "$_jail") $(get_jail_ip6 "$_jail");
			do
				echo "GRANT ALL PRIVILEGES ON $_pw_jname.* to '$_pw_jname'@'${_ip}' IDENTIFIED BY '$WEBHOST_MYSQL_SERVER_PASSWORD';" \
					| stage_mysql_query || exit
			done
		done

	fi
}


install_webhost()
{
	local _php_modules="$WEBHOST_PHP_MODULES"

	install_php "$_php_ver" "$_php_modules" || exit
	case "$WEBHOST_SERVER_TYPE" in
		nginx)
			install_nginx
			configure_nginx "$_pw_jname"
			configure_nginx_server
			;;
		apache)
			stage_pkg_install mod_php$_php_ver
			install_apache_setup
			stage_sysrc apache24_enable=YES
			;;
	esac
}

install_apache_setup()
{
	local _htcnf="$STAGE_MNT/usr/local/etc/apache24/Includes/$_pw_jname.conf"
	tee "$_htcnf" <<EO_WEBHOST_APACHE24
<FilesMatch "\.php$">
    SetHandler application/x-httpd-php
</FilesMatch>
<FilesMatch "\.phps$">
    SetHandler application/x-httpd-php-source
</FilesMatch>

<VirtualHost _default_:80>
    ServerName $_pw_jname
    DocumentRoot $WEBHOST_DOCUMENT_ROOT
    DirectoryIndex index.php

    #<Files "*.php">
    #   SetHandler php-script
    #</Files>

    <Directory "$WEBHOST_DOCUMENT_ROOT">
        Require all granted
    </Directory>
</VirtualHost>
EO_WEBHOST_APACHE24

}

configure_nginx_server()
{
	local _datadir="$ZFS_DATA_MNT/$_pw_jname"
	if [ -f "$_datadir/etc/nginx-server.conf" ]; then
		tell_status "preserving /data/etc/nginx-server.conf"
		return
	fi

	local _add_server="" _add_location=""
	if [ "$TOASTER_USE_TMPFS" = "1" ]; then
		tee -a $STAGE_MNT/etc/rc.local <<'EO_RC_LOCAL'
TEMPDIRS="/tmp/nginx/fastcgi_temp /tmp/nginx/client_body_temp"
mkdir -p $TEMPDIRS
chown www:www $TEMPDIRS
chmod 0700 $TEMPDIRS
EO_RC_LOCAL
		stage_exec service local start
		_add_server="client_body_temp_path /tmp/nginx/client_body_temp;"
		_add_location="fastcgi_temp_path /tmp/nginx/fastcgi_temp;"
	fi

	tell_status "saving /data/etc/nginx-locations.conf"
	tee "$_datadir/etc/nginx-locations.conf" <<EO_NGINX_LOCALS

	server_name $_pw_jname;
	root   $WEBHOST_DOCUMENT_ROOT;
	index  $WEBHOST_DOCUMENT_INDEX;

	$_add_server
	location /$_pw_jname {
		alias $WEBHOST_DOCUMENT_ROOT;
	}

	location ~ \\.php\$ {
		include        /usr/local/etc/nginx/fastcgi_params;
		fastcgi_index  index.php;
		fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
		fastcgi_pass   php;
		$_add_location
	}
EO_NGINX_LOCALS
}

configure_webhost()
{
	configure_php_ini "$_pw_jname"
	sed -i.bak -e '/^mysqli\.default_socket/d' $STAGE_MNT/usr/local/etc/php.ini
	echo "mysqli.default_socket = /var/run/mysql/mysql.sock" | tee -a $STAGE_MNT/usr/local/etc/php.ini
	if [ "$WEBHOST_SERVER_TYPE" = nginx ]; then
		configure_php_fpm "$_pw_jname"
		configure_nginx "$_pw_jname"
		configure_nginx_server

		#tell_status "installing mime.types"
		#fetch -o "$STAGE_MNT/usr/local/etc/mime.types" \
		#	http://svn.apache.org/repos/asf/httpd/httpd/trunk/docs/conf/mime.types
	fi

	tell_status "apply webhost customizations to php.ini"
	sed -i.bak \
		-e "/^session.gc_maxlifetime/ s/= *[1-9][0-9]*/= 21600/" \
		-e "/^post_max_size/ s/= *[1-9][0-9]*M/= ${WEBHOST_ATTACHMENT_SIZE_MB}M/" \
		-e "/^upload_max_filesize/ s/= *[1-9][0-9]*M/= ${WEBHOST_ATTACHMENT_SIZE_MB}M/" \
		"$STAGE_MNT/usr/local/etc/php.ini" || exit
}

configure_webhost_always() {
	local _datadir="$ZFS_DATA_MNT/$_pw_jname"
	install_webhost_mysql

	# apply webhost customizations to php.ini
	sed -i.bak \
		-e "/session.gc_maxlifetime/ s/= *[1-9][0-9]*/=21600/" \
		-e "/memory_limit/ s/= *[1-9][0-9]*M/=${WEBHOST_PHP_MEMORY_LIMIT_MB}M/" \
		-e "/post_max_size/ s/= *[1-9][0-9]*M/=${WEBHOST_ATTACHMENT_SIZE_MB}M/" \
		-e "/upload_max_filesize/ s/= *[1-9][0-9]*M/=${WEBHOST_ATTACHMENT_SIZE_MB}M/" \
		-e "/^date\\.timezone/ s,=.*\$,= Europe/London," \
		"$STAGE_MNT/usr/local/etc/php.ini"
}

start_webhost()
{
	case "$WEBHOST_SERVER_TYPE" in
		nginx)
			start_php_fpm
			start_nginx
			;;
		apache)	stage_exec service apache24 start ;;
	esac
}

test_webhost()
{
	case "$WEBHOST_SERVER_TYPE" in
		nginx)
			test_php_fpm
			test_nginx
			;;
		#apache) test_apache ;;
	esac
	echo "it worked"
}

tell_settings WEBHOST
base_snapshot_exists || exit
create_staged_fs "$_pw_jname"
start_staged_jail "$_pw_jname"
create_webhost_user
install_webhost
deploy_webhost
configure_webhost
configure_webhost_always
start_webhost
test_webhost
TOASTER_PKG_AUDIT=0 promote_staged_jail "$_pw_jname"
