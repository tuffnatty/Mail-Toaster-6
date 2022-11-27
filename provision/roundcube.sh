#!/bin/sh

set -e

. mail-toaster.sh

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA=""
export JAIL_FSTAB=""

mt6-include php
mt6-include nginx
mt6-include mysql

PHP_VER="85"


install_roundcube_mysql()
{
	assure_jail mysql

	local _init_db=0
	if ! mysql_db_exists roundcubemail; then
		tell_status "creating roundcube mysql db"
		mysql_create_db roundcubemail || mysql_error_warning

		if mysql_db_exists roundcubemail; then
			_init_db=1
		fi
	fi

	local _active_cfg="$ZFS_JAIL_MNT/roundcube/usr/local/www/roundcube/config/config.inc.php"
	if [ -f "$_active_cfg" ]; then
		local _rcpass
		_rcpass=$(grep '//roundcube:' $_active_cfg | grep ^\$config | cut -f3 -d: | cut -f1 -d@)
		if [ -n "$_rcpass" ] && [ "$_rcpass" != "pass" ]; then
			echo "preserving roundcube password $_rcpass"
		fi
	else
		_rcpass="$ROUNDCUBE_MYSQL_PASS"
	fi

	local _rcc_dir="$STAGE_MNT/usr/local/www/roundcube/config"
	sed_inplace \
		-e "s/roundcube:pass@/roundcube:${_rcpass}@/" \
		-e "s/@localhost\//@$(get_jail_ip mysql)\//" \
		"$_rcc_dir/config.inc.php"

	if [ "$_init_db" = "1" ]; then
		tell_status "configuring roundcube mysql permissions"

		mysql_create_user roundcube "$_rcpass" roundcubemail \
			"$(get_jail_ip roundcube)" "$(get_jail_ip stage)" \
			"$(get_jail_ip6 roundcube)" "$(get_jail_ip6 stage)"

		roundcube_init_db
	fi
}

roundcube_init_db()
{
	tell_status "initializing roundcube db"
	pkg install -y curl
	start_roundcube

	local _curl_flags=""
	[ "$TOASTER_INGRESS_JAIL" != "haproxy" ] || _curl_flags="--haproxy-protocol"

	# since 1.7 the installer entry point is public_html/installer.php; the
	# installer/ dir it loads sits outside the document root
	if ! curl -i -sS --fail $_curl_flags -F initdb='Initialize database' -XPOST \
		"http://$(get_jail_ip stage)/installer.php?_step=3"; then
		fatal_err "roundcube installer did not respond at /installer.php"
	fi
}

update_roundcube_db()
{
	tell_status "applying roundcube db schema updates"

	# updatedb.sh applies pending SQL/ updates and records the schema version.
	# Bumping the version without applying them leaves roundcube throwing
	# "Oops something went wrong"
	if ! stage_exec /usr/local/bin/php /usr/local/www/roundcube/bin/updatedb.sh \
		--package=roundcube --dir=/usr/local/www/roundcube/SQL; then
		tell_status "WARNING: roundcube schema update failed. If the SQL updates
were already applied by hand, record the version with:
  updatedb.sh --package=roundcube --dir=SQL --version=<applied version>"
	fi
}

migrate_roundcube_nginx_conf()
{
	local _conf="$ZFS_DATA_MNT/roundcube/etc/nginx/server.d/roundcube.conf"

	if [ ! -f "$_conf" ] || grep -q public_html "$_conf"; then return; fi

	# 1.7 serves from public_html and routes assets through static.php, so a
	# pre-1.7 server block can't be patched up in place
	tell_status "roundcube 1.7 requires a new nginx config, saving $_conf.pre-1.7"
	mv "$_conf" "$_conf.pre-1.7"
}

install_local_ports() {
	for _port; do
		cp -a "ports/$_port" "$STAGE_MNT/root/" || return 1

		tell_status "install $_port"
		jexec "$SAFE_NAME" make -C "/root/$_port" showconfig build deinstall install clean BATCH=yes || return 1

		rm -fr "$STAGE_MNT/root/$_port"
		pkg -j "$SAFE_NAME" lock "$_port"
	done
}

install_roundcube_plugins()
{
	local _rc_plugins="contextmenu html5_notifier larry"
	if [ -d "$ZFS_DATA_MNT/spamassassin/etc" ]; then
		_rc_plugins="$_rc_plugins sauserprefs"
	fi

	[ -n "$ROUNDCUBE_EXTENSIONS" ] || ROUNDCUBE_EXTENSIONS="$_rc_plugins"

	if [ "$ROUNDCUBE_FROM_LOCAL_PORT" = "1" ]; then
		install_local_ports $(printf "roundcube-%s " $ROUNDCUBE_EXTENSIONS)
		return 0
	fi

	for _pi in $ROUNDCUBE_EXTENSIONS; do
		tell_status "installing roundcube plugin $_pi"
		stage_pkg_install roundcube-${_pi}-php${PHP_VER}
	done
}

install_roundcube()
{
	local _php_modules="ctype curl dom exif fileinfo filter gd iconv intl mbstring pdo_sqlite session xml zip"

	if [ "$ROUNDCUBE_SQL" = "1" ]; then
		_php_modules="$_php_modules pdo_mysql"
	fi

	install_php $PHP_VER "$_php_modules"
	install_nginx

	tell_status "installing roundcube"
	case "$ROUNDCUBE_CORE_PLUGINS" in
		*enigma*)	stage_pkg_install gnupg ;;
	esac
	if [ "$ROUNDCUBE_FROM_LOCAL_PORT" = "1" ]; then
		tell_status "configure roundcube port options"
		stage_make_conf roundcube_SET 'mail_roundcube_SET=GD PSPELL SQLITE'
		stage_make_conf roundcube_UNSET 'mail_roundcube_UNSET=DOCS EXAMPLES LDAP NSC MYSQL PGSQL'

		install_local_ports roundcube
	else
		stage_pkg_install roundcube-php${PHP_VER}
	fi

	install_roundcube_plugins
	install_logo
}

configure_nginx_server()
{
	local _add_server="" _add_location=""

	if [ "$TOASTER_USE_TMPFS" = "1" ]; then
		tee -a $STAGE_MNT/etc/rc.local <<'EO_RC_LOCAL'
TEMPDIRS="/tmp/nginx/fastcgi_temp /tmp/nginx/client_body_temp"
# shellcheck disable=SC2086  # intentional word-splitting to expand TEMPDIRS into multiple args
mkdir -p $TEMPDIRS
chown www:www $TEMPDIRS
chmod 0700 $TEMPDIRS
EO_RC_LOCAL
		stage_exec service local start
		_add_server="client_body_temp_path /tmp/nginx/client_body_temp;"
		_add_location="fastcgi_temp_path /tmp/nginx/fastcgi_temp;"
	fi

	_NGINX_SERVER="
		server_name  roundcube;

		root   /usr/local/www/roundcube/public_html;
		index  index.php;

		$_add_server
		location = /roundcube { return 301 /roundcube/; }
		rewrite ^/roundcube/(.*)\$ /\$1 last;
		location = / { rewrite ^ /index.php last; }

		location ~ ^/(bin|SQL|config|temp|logs)\$ {
			deny all;
		}

		location ~ \\.inc\$ {
			deny all;
		}

		# for performance, robustness, and security, bypass static.php for assets
		location ~* ^/static.php/(?<asset_path>.+\.(?:css|gif|htc|ico|js|jpe?g|png|swf|webp|ttf|svg|woff|woff2|eot))\$ {
			alias /usr/local/www/roundcube/\$asset_path;
			expires       max;
			access_log    off;
			log_not_found off;
		}

		location / {
			try_files \$uri /static.php\$uri\$is_args\$args;
		}

		location ~ \\.php(/|\$) {
			include        /usr/local/etc/nginx/fastcgi_params;
			fastcgi_split_path_info ^(.+\\.php)(/.*)\$;
			fastcgi_index  index.php;
			fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
			fastcgi_param  PATH_INFO        \$fastcgi_path_info;
			fastcgi_pass   php;
			$_add_location
		}
"
	export _NGINX_SERVER
	configure_nginx_server_d roundcube
}

install_logo()
{
	local _logo_path="$ZFS_DATA_MNT/roundcube/logo.svg"
	if [ ! -f "$_logo_path" ]; then
		tell_status "PRO TIP: populate $_logo_path"
		return;
	fi

	tell_status "installing custom logo"
	cp "$_logo_path" "$STAGE_MNT/usr/local/www/roundcube/skins/elastic/images/"
	cp "$_logo_path" "$STAGE_MNT/usr/local/www/roundcube/skins/larry/images/"
}

configure_roundcube_php()
{
	tell_status "apply roundcube customizations to php.ini"
	sed_inplace \
		-e "/^session.gc_maxlifetime/ s/= *[1-9][0-9]*/= 21600/" \
		-e "/^post_max_size/ s/= *[1-9][0-9]*M/= ${ROUNDCUBE_ATTACHMENT_SIZE_MB}M/" \
		-e "/^upload_max_filesize/ s/= *[1-9][0-9]*M/= ${ROUNDCUBE_ATTACHMENT_SIZE_MB}M/" \
		"$STAGE_MNT/usr/local/etc/php.ini"
}

configure_roundcube_plugins()
{
	local _plugins_dir="$STAGE_MNT/usr/local/www/roundcube/plugins"

	for _plugin in $ROUNDCUBE_CORE_PLUGINS $ROUNDCUBE_EXTENSIONS; do case "$_plugin" in
		automatic_addressbook)
			tell_status "configure the $_plugin plugin"
			local _migration_dir="$_plugins_dir/automatic_addressbook/SQL"
			if [ "$ROUNDCUBE_SQL" = "1" ]; then
				mysql_query < "$_migration_dir/mysql.initial.sql" || true
			else
				stage_exec sqlite3 -bail /data/sqlite.db < "$_migration_dir/sqlite.initial.sql" || true
			fi
			;;
		enigma)
			tell_status "configure the $_plugin plugin"
			local _rcc_pgp_homedir="pgp"
			mkdir -p "$ZFS_DATA_MNT/roundcube/$_rcc_pgp_homedir"
			sed -e '/^\$config..enigma_pgp_homedir.. = /'" s,null,'/data/$_rcc_pgp_homedir'," \
				< "$_plugins_dir/enigma/config.inc.php.dist" \
				> "$_plugins_dir/enigma/config.inc.php"
			;;
		managesieve)
			tell_status "configure the $_plugin plugin"
			sed -e "/'managesieve_host'/ s/localhost/dovecot/" \
				< "$_plugins_dir/managesieve/config.inc.php.dist" \
				> "$_plugins_dir/managesieve/config.inc.php"
			;;
		markasjunk)
			tell_status "configure the $_plugin plugin"
			sed \
				< "$_plugins_dir/markasjunk/config.inc.php.dist" \
				> "$_plugins_dir/markasjunk/config.inc.php"
			;;
		newmail_notifier)
			tell_status "configure the $_plugin plugin"
			sed \
				-e '/^\$config..newmail_notifier_basic.. = / s,false,true,' \
				-e '/^\$config..newmail_notifier_sound.. = / s,false,true,' \
				-e '/^\$config..newmail_notifier_desktop.. = / s,false,true,' \
				< "$_plugins_dir/newmail_notifier/config.inc.php.dist" \
				> "$_plugins_dir/newmail_notifier/config.inc.php"
			;;
	esac; done
}

configure_roundcube()
{
	configure_php roundcube
	configure_nginx roundcube
	migrate_roundcube_nginx_conf
	configure_nginx_server

	local _local_path="/usr/local/www/roundcube/config/config.inc.php"
	preserve_file roundcube "$_local_path"

	configure_roundcube_php
	configure_roundcube_plugins

	local _stage_cfg="${STAGE_MNT}${_local_path}"
	if [ -f "$_stage_cfg" ]; then return; fi

	tell_status "installing default $_stage_cfg"
	cp "$_stage_cfg.sample" "$_stage_cfg"

	tell_status "customizing $_stage_cfg"
	local _dovecot_ip
	if  [ -z "$ROUNDCUBE_DEFAULT_HOST" ];
	then
		_dovecot_ip=$(get_jail_ip dovecot)
	else
		_dovecot_ip="$ROUNDCUBE_DEFAULT_HOST"
	fi

	sed_inplace \
		-e "/'default_host'/ s/'localhost'/'$_dovecot_ip'/" \
		-e "/'smtp_server'/  s/= '.*'/= 'ssl:\/\/$TOASTER_MSA'/" \
		-e "/'smtp_port'/    s/25;/465;/ ; s/587;/465;/" \
		-e "/'imap_host'/    s/localhost/$_dovecot_ip/" \
		-e "/'smtp_host'/    s/= '.*'/= ssl:\/\/$TOASTER_MSA:465/" \
		-e "/'smtp_user'/    s/'';/'%u';/" \
		-e "/'smtp_pass'/    s/'';/'%p';/" \
		-e "/'product_name'/ s/'Roundcube Webmail'/$(sed_replacement_quote "$(php_quote "$ROUNDCUBE_PRODUCT_NAME")")/" \
		-e '/^\$config..plugins/,/^];$/d' \
		"$_stage_cfg"

	tee -a "$_stage_cfg" <<'EO_RC_ADD'
$config['log_driver'] = 'syslog';
$config['session_lifetime'] = 30;
$config['enable_installer'] = true;
$config['mime_types'] = '/usr/local/etc/nginx/mime.types';
//$config['use_https'] = true;
$config['smtp_conn_options'] = array(
 'ssl'            => array(
   'verify_peer'  => false,
   'verify_peer_name' => false,
   'verify_depth' => 3,
   'cafile'       => '/etc/ssl/cert.pem',
 ),
);
//$config['request_path'] = '/roundcube';
EO_RC_ADD

	local _use_https="true" _rcc_plugins=""
	[ "${TOASTER_INGRESS_SSL_TERMINATION}" = 0 ] || _use_https="false"
	[ -z "$ROUNDCUBE_EXTENSIONS$ROUNDCUBE_CORE_PLUGINS" ] || \
		_rcc_plugins="$(printf "'%s', " $ROUNDCUBE_EXTENSIONS $ROUNDCUBE_CORE_PLUGINS | sed 's/, $//')"

	tee -a "$_stage_cfg" <<EO_RC_ADD2
\$config['use_https'] = $_use_https;
\$config['plugins'] = [$_rcc_plugins];
EO_RC_ADD2

	if [ "$ROUNDCUBE_SQL" = "1" ]; then
		install_roundcube_mysql
	else
		sed_inplace \
			-e "/^\$config\['db_dsnw'/ s/= .*/= 'sqlite:\/\/\/\/data\/sqlite.db?mode=0646';/" \
			"$_stage_cfg"

		if [ ! -f "$ZFS_DATA_MNT/roundcube/sqlite.db" ]; then
			mkdir -p "$STAGE_MNT/data"
			chown 80:80 "$STAGE_MNT/data"
			roundcube_init_db
		fi
	fi

	sed_inplace \
		-e "/enable_installer/ s/true/false/" \
		"$_stage_cfg"
}

fixup_url()
{
	# hack for roundcube 1.6.0 bug
	# see https://github.com/roundcube/roundcubemail/issues/8738, #8170, #8770
	sed_inplace \
		-e "/return \$prefix/    s/\./\. 'roundcube\/' \./" \
		"$STAGE_MNT/usr/local/www/roundcube/program/include/rcmail.php"
}

start_roundcube()
{
	# fixup_url
	start_php_fpm
	start_nginx
}

test_roundcube()
{
	test_php_fpm
	test_nginx
	echo "it worked"
}

tell_settings ROUNDCUBE
base_snapshot_exists || exit
create_staged_fs roundcube
start_staged_jail roundcube
install_roundcube
configure_roundcube
update_roundcube_db
start_roundcube
test_roundcube
promote_staged_jail roundcube
