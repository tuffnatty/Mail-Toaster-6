#!/bin/sh
set -e

. mail-toaster.sh || exit

export JAIL_START_EXTRA=""
export JAIL_CONF_EXTRA=""

mt6-include nginx

configure_nginx_server()
{
	_NGINX_SERVER='
		server_name nginxfront $TOASTER_HOSTNAME;

		# serve ACME requests from /data
		location /.well-known/acme-challenge {
		  root /data;
			try_files $uri =404;
		}

		location /.well-known/pki-validation {
			root /data;
			try_files $uri =404;
		}

		# Forbid access to other dotfiles
		location ~ /\.(?!well-known).* {
			return 403;
		}

		location / {
			root   /data/htdocs;
			index  index.html index.htm;
		}
'
	export _NGINX_SERVER
	configure_nginx_server_d nginxfront
}

install_nginxfront()
{
	install_nginx
	tee "$STAGE_MNT/usr/local/etc/nginx/proxy_params" <<'EO_PROXY_PARAMS'
proxy_set_header Host $http_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
EO_PROXY_PARAMS
}

configure_nginx_dot_conf() {
	tell_status "configuring nginxfront"

	local _ssl_params="$STAGE_MNT/usr/local/etc/nginx/ssl_params"
	if [ -f "$_ssl_params" ]; then
		tell_status "preserving $_ssl_params"
	else
		tee "$STAGE_MNT/usr/local/etc/nginx/ssl_params" >/dev/null <<EO_SSL_PARAMS
		listen 443 ssl http2;

		ssl_certificate /data/etc/ssl/$TOASTER_HOSTNAME/certs/fullchain.cer;
		ssl_certificate_key /data/etc/ssl/$TOASTER_HOSTNAME/private/$TOASTER_HOSTNAME.key;
		ssl_dhparam /etc/ssl/dhparam.pem;
		ssl_protocols TLSv1.2 TLSv1.3;
		ssl_prefer_server_ciphers on;
		ssl_ecdh_curve secp521r1:secp384r1;

		#strictest
		#ssl_ciphers EECDH+AESGCM:EECDH+AES256;

		#secure
		ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;

		#for IE6/WinXP
		#ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:ECDHE-RSA-AES128-GCM-SHA256:AES256+EECDH:DHE-RSA-AES128-GCM-SHA256:AES256+EDH:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA256:AES128-SHA256:AES256-SHA:AES128-SHA:DES-CBC3-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4";

		ssl_session_cache shared:TLS:2m;
		ssl_buffer_size 4k;

		# OCSP stapling
		#ssl_stapling on;
		#ssl_stapling_verify on;
		#resolver 1.1.1.1 1.0.0.1 [2606:4700:4700::1111] [2606:4700:4700::1001]; # Cloudflare

		# Set HSTS to 365 days
		add_header Strict-Transport-Security 'max-age=31536000; includeSubDomains; preload' always;
EO_SSL_PARAMS
	fi

	local _data_cf="$ZFS_DATA_MNT/nginxfront/etc/nginx.conf"
	if [ -f "$_data_cf" ]; then
		tell_status "preserving $_data_cf"
		return
	fi

	tee "$_data_cf" <<EO_NGINX_CONF
#user  nobody;
worker_processes  1;

# This default error log path is compiled-in to make sure configuration parsing
# errors are logged somewhere, especially during unattended boot when stderr
# isn't normally logged anywhere. This path will be touched on every nginx
# start regardless of error log location configured here. See
# https://trac.nginx.org/nginx/ticket/147 for more info. 
#
#error_log  /var/log/nginx/error.log;
error_log /data/log/nginx/error.log;
#

#pid        logs/nginx.pid;


events {
	worker_connections  1024;
}


http {
	include       /usr/local/etc/nginx/mime.types;
	default_type  application/octet-stream;

	log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
	                  '\$status \$body_bytes_sent "\$http_referer" '
			  '"\$http_user_agent" "\$http_x_forwarded_for"';
	access_log /data/log/nginx/access.log main;

	
	sendfile        on;
	#tcp_nopush     on;

	#keepalive_timeout  0;
	keepalive_timeout  65;

	gzip  on;

	client_max_body_size 25m;

	upstream roundcube {
		server $(get_jail_ip roundcube):80;
	}

	server {
		listen       80 default_server;
        	server_name  _;
		location /.well-known/acme-challenge {
			root   /data/htdocs;
		}
		location / {
			return 301 https://\$host\$request_uri;
		}
	}
	
	server {
		server_name $TOASTER_HOSTNAME www.$TOASTER_HOSTNAME;
		include        /usr/local/etc/nginx/ssl_params;
		location / {
			root /data/htdocs;
			try_files \$uri \$uri/ index.html;
		}
	}

	server {
		server_name mail.$TOASTER_HOSTNAME;
		include        /usr/local/etc/nginx/ssl_params;
		location / {
			include        /usr/local/etc/nginx/proxy_params;
			proxy_pass http://roundcube;
			proxy_cache off;
		}
	}
}
EO_NGINX_CONF
}

configure_nginxfront()
{
	if [ ! -d "$ZFS_DATA_MNT/nginxfront/etc" ]; then
		tell_status "creating /data/etc/ssl"
		mkdir -p "$ZFS_DATA_MNT/nginxfront/etc/ssl"
	fi

	if [ -f ~acme/certs/$TOASTER_HOSTNAME/fullchain.cer ]; then
		tell_status "installing certificates"
		mkdir -p "$ZFS_DATA_MNT/nginxfront/etc/ssl/$TOASTER_HOSTNAME/certs"
		mkdir -p "$ZFS_DATA_MNT/nginxfront/etc/ssl/$TOASTER_HOSTNAME/private"
		cp ~acme/certs/$TOASTER_HOSTNAME/fullchain.cer "$ZFS_DATA_MNT/nginxfront/etc/ssl/$TOASTER_HOSTNAME/certs/"
		cp ~acme/certs/$TOASTER_HOSTNAME/$TOASTER_HOSTNAME.key "$ZFS_DATA_MNT/nginxfront/etc/ssl/$TOASTER_HOSTNAME/private/"
	else
		tell_status "Certificates not found, on success run: provision letsencrypt"
	fi

	configure_nginx_dot_conf
	stage_sysrc nginx_config="/data/etc/nginx.conf"

	if [ -f "$STAGE_MNT/usr/local/etc/nginx/nginx.conf" ]; then
		rm "$STAGE_MNT/usr/local/etc/nginx/nginx.conf"
	fi
	stage_exec ln -s /data/etc/nginx.conf /usr/local/etc/nginx/nginx.conf

	if [ ! -d "$STAGE_MNT/var/run/nginxfront" ]; then
		# useful for stats socket
		mkdir "$STAGE_MNT/var/run/nginxfront"
	fi

	configure_nginxfront_tls || true

	_htdocs="$ZFS_DATA_MNT/nginxfront/htdocs"
	if [ ! -d "$_htdocs" ]; then
	    mkdir -p "$_htdocs"
	    echo "Coming soon" > "$_htdocs/index.html"
	fi

	echo_do mkdir -p "$ZFS_DATA_MNT/nginxfront/log/nginx"

	local _pf_etc
	_pf_etc="$(get_jail_etc nginxfront)/pf.conf.d"
	store_config "$_pf_etc/rdr.conf" <<EO_PF
rdr pass inet  proto tcp from any to <ext_ip4> port { 80 443 } -> $(get_jail_ip  nginxfront)
rdr pass inet6 proto tcp from any to <ext_ip6> port { 80 443 } -> $(get_jail_ip6 nginxfront)
EO_PF
}

start_nginxfront()
{
	tell_status "starting nginxfront"
	stage_sysrc nginx_enable=YES

	if [ -f "$ZFS_JAIL_MNT/nginxfront/var/run/nginx.pid" ]; then
		echo "nginx is running, this might fail."
	fi

	stage_exec service nginx start
}

test_nginxfront()
{
	tell_status "testing nginxfront"
	if [ ! -f "$ZFS_JAIL_MNT/nginxfront/var/run/nginx.pid" ]; then
		stage_listening 80
		stage_listening 443 || true
		echo "it worked"
		return
	fi

	echo "previous nginx is running, ignoring errors"
	#sockstat -l -4 -6 -p 443 -j "$(jls -j stage jid)"
	sockstat -l -4 -6 -p 80 -j "$(jls -j stage jid)"
}

export TOASTER_PKGBASE=1
base_snapshot_exists || exit
create_staged_fs nginxfront
start_staged_jail nginxfront
install_nginxfront
configure_nginxfront
start_nginxfront
test_nginxfront
promote_staged_jail nginxfront
