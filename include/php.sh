#!/bin/sh

# PHP-FPM can listen on a UNIX socket or a TCP port. Use 'tcp' if your web
# server will load balance to a pool of PHP-FPM servers. Else use sockets
# and avoid the TCP overhead.
PHP_LISTEN_MODE=${PHP_LISTEN_MODE:="socket"}

install_php()
{
	_version="$1"; if [ -z "$_version" ]; then _version="56"; fi

	tell_status "installing PHP $_version"

	_ports="php$_version"
	_modules="$2"

	if [ "$TOASTER_MYSQL" = "1" ]; then
		tell_status "including php mysqli & PDO_mysql modules"
		_modules="$_modules pdo_mysql mysqli"
	fi

	for m in $_modules
	do
		_ports="$_ports php$_version-$m"
	done

	if [ "$_version" = "74" ]; then
		# /usr/ports should have lang/php74
		stage_pkg_install portconfig pkgconf autoconf automake pcre2 gmake libxml2
		stage_make_conf php74_SET 'lang_php74_SET=FPM'
		stage_make_conf php74_UNSET 'lang_php74_UNSET=CGI CLI EMBED'
		stage_port_install lang/php74
		for _port in ${_ports#php74 }; do
			stage_port_install "$(cd /usr/ports && echo */"$_port")"
		done
	else
		stage_pkg_install $_ports || exit
	fi
	install_php_newsyslog
}

install_php_newsyslog() {
	stage_enable_newsyslog

	tell_status "enabling PHP-FPM log file rotation"
	store_config "$STAGE_MNT/etc/newsyslog.conf.d/php-fpm.conf" <<EO_FPM_NSL
# rotate the file after it reaches 1M
/var/log/php-fpm.log 600 7	1024	*	BCX	/var/run/php-fpm.pid 30
EO_FPM_NSL
}

configure_php_ini()
{
	local _php_ini="$STAGE_MNT/usr/local/etc/php.ini"

	if [ -n "$1" ]; then
		if [ -f "$ZFS_JAIL_MNT/$1/usr/local/etc/php.ini" ]; then
			tell_status "preserving php.ini"
			cp "$ZFS_JAIL_MNT/$1/usr/local/etc/php.ini" "$_php_ini"
			return
		fi
	fi

	tell_status "getting the timezone"
	TZ=$(md5 -q /etc/localtime)
	TIMEZONE=$(find /usr/share/zoneinfo -type f -print0 | xargs -0 md5 -r | grep "$TZ" | awk '{print $2; exit}' |cut -c21-)

	if [ -z "$TIMEZONE" ]; then
		TIMEZONE="America\/Los_Angeles"
	fi

	tell_status "Setting TIMEZONE to :  $TIMEZONE "

	cp "$STAGE_MNT/usr/local/etc/php.ini-production" "$_php_ini" || exit
	sed_inplace \
		-e "s|^;date.timezone =|date.timezone = $TIMEZONE|" \
		-e '/^post_max_size/ s/8M/25M/' \
		-e '/^upload_max_filesize/ s/2M/25M/' \
		"$_php_ini"

}

configure_php_fpm() {

	tell_status "enable syslog for PHP-FPM"
	sed_inplace \
		-e '/^;error_log/ s/^;//' \
		-e '/^error_log/ s/= .*/= syslog/' \
		"$STAGE_MNT/usr/local/etc/php-fpm.conf"

	if [ "$PHP_LISTEN_MODE" = "tcp" ]; then
		return
	fi

	tell_status "switch PHP-FPM from TCP to unix socket"
	local _fpmconf="$STAGE_MNT/usr/local/etc/php-fpm.conf"
	if [ -f "$STAGE_MNT/usr/local/etc/php-fpm.d/www.conf" ]; then
		_fpmconf="$STAGE_MNT/usr/local/etc/php-fpm.d/www.conf"
	fi

	sed_inplace \
		-e "/^listen =/      s|= .*|= '/tmp/php-cgi.socket';|" \
		-e '/^;listen.owner/ s/^;//' \
		-e '/^;listen.group/ s/^;//' \
		-e '/^;listen.mode/  s/^;//' \
		"$_fpmconf"
}

configure_php()
{
	configure_php_ini "$1"
	configure_php_fpm "$1"
}

php_fpm_name() {
	# before 8.0, the service is php-fpm; after 8.0 it's php_fpm
	if [ -x "$STAGE_MNT/usr/local/etc/rc.d/php_fpm" ]; then echo php_fpm; else echo php-fpm; fi
}

php_fpm_process_name() {
	echo php-fpm
}

start_php_fpm()
{
	tell_status "starting PHP FPM"
	stage_sysrc php_fpm_enable=YES
	local _php_fpm="$(php_fpm_name)"
	echo_stage_exec service "$_php_fpm" start || echo_stage_exec service "$_php_fpm" restart
}

test_php_fpm()
{
	tell_status "testing PHP FPM (FastCGI Process Manager) is running"
	stage_test_running "$(php_fpm_process_name)"

	if [ "$PHP_LISTEN_MODE" = "tcp" ]; then
		tell_status "testing PHP FPM is listening"
		stage_listening 9000
	else
		tell_status "testing PHP FPM socket exists"
		if [ ! -S "$STAGE_MNT/tmp/php-cgi.socket" ]; then
			echo "no PHP-FPM socket found!"
			exit
		fi
	fi
}

php_quote()
{
	stage_exec php -r 'var_export($argv[1]);' "$1"
}
