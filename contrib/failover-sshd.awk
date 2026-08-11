#!/usr/bin/awk -f
# FIXME: test IPv6
function get_ip(nic, proto,  p, r) {
	p = "/sbin/ifconfig " nic " " proto
	while (p | getline)
		if ($1 == proto && $2 !~ /^fe80/) { r = $2; break }
	close(p)
	return r
}
function get_ips(  p, n) {
	p = "/usr/bin/netstat -rn"
	while (p | getline)
		if ($1 == "default")
			NICS[++n] = $4
	close(p)
	IP4 = get_ip(NICS[1], "inet")
	IP6 = get_ip(NICS[n], "inet6")
	return 1
}
function listening(ip,  p, r) {
	if (!ip) return 1
	p = "/usr/bin/sockstat -Ll46p " PORT
	while (p | getline)
		if ($6 == "*:"PORT || $6 == ip":"PORT || $6 == "["ip"]:"PORT)
			r = 1
	close(p)
	if (r) return r
	print "Nothing is listening on "ip" port "PORT >"/dev/stderr"
}
BEGIN {
	PORT = 22
	while (get_ips() && !(listening(IP4) && listening(IP6))) {
		print "Starting failover sshd on "IP4" "IP6 >"/dev/stderr"
		system("/usr/sbin/sshd -p "PORT \
			(IP4 ? " -o ListenAddress="IP4 : "") \
			(IP6 ? " -o ListenAddress="IP6 : ""))
		system("/bin/sleep 3")
	}
	if (!IP4 && !IP6) print "No public IPs" >"/dev/stderr"
}
