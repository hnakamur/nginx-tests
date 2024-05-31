#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for HTTP/2 protocol with ssl and http proxy cache.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
	->has(qw/http http_ssl http_v2 proxy cache socket_ssl/)->plan(32)
	->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:1m;

    map $arg_slow $rate {
        default 8k;
        1       200;
    }

    server {
        listen       127.0.0.1:8080 http2 ssl;
        server_name  localhost;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        location / {
            proxy_pass   http://127.0.0.1:8081;
            proxy_cache  NAME;
            proxy_cache_valid 1m;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            limit_rate $rate;
            add_header age $arg_age;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->write_file('t.html', 'SEE-THIS');

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

###############################################################################

my $s = getconn(port(8080));
ok($s, 'ssl connection');

test_age($s, '/t.html', undef, 0, 2);
my $t1 = time();

test_age($s, '/t.html?age=1', 1, 1, 3);
test_age($s, '/t.html?slow=1', undef, 1, 3);
test_age($s, '/t.html?age=1&slow=1', 1, 2, 4);

$t->stop();

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

$s = getconn(port(8080));
ok($s, 'ssl connection');

my $rt1 = time() - $t1; # resident time
test_age($s, '/t.html', $rt1 + 2, $rt1 + 2, $rt1 + 4);

$t->stop();

###############################################################################

sub getconn {
	my ($port) = @_;
	my $s;

	eval {
		my $sock = Test::Nginx::HTTP2::new_socket($port, SSL => 1,
			alpn => 'h2');
		$s = Test::Nginx::HTTP2->new($port, socket => $sock)
			if $sock->alpn_selected();
	};

	return $s if defined $s;

	eval {
		my $sock = Test::Nginx::HTTP2::new_socket($port, SSL => 1,
			npn => 'h2');
		$s = Test::Nginx::HTTP2->new($port, socket => $sock)
			if $sock->next_proto_negotiated();
	};

	return $s;
}

sub test_age {
    my ($s, $path, $age1, $age2, $age3) = @_;

    my ($sid, $frames, $frame);

    $sid = $s->new_stream({ path => $path });
    $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
    ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
    is($frame->{headers}->{':status'}, 200, 'status');
    is($frame->{headers}->{'age'}, $age1, 'age');

    $sid = $s->new_stream({ path => $path });
    $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
    ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
    is($frame->{headers}->{':status'}, 200, 'status');
    is($frame->{headers}->{'age'}, $age2, 'age');

    select undef, undef, undef, 2.0;

    $sid = $s->new_stream({ path => $path });
    $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
    ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
    is($frame->{headers}->{':status'}, 200, 'status');
    is($frame->{headers}->{'age'}, $age3, 'age');
}

###############################################################################
