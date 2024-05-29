#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.
# (C) Hiroaki Nakamura

# Tests for age in HTTP/2 ssl proxy cache.

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
	->has(qw/http http_ssl http_v2 proxy cache socket_ssl/)->plan(13)
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
        1       100;
    }

    server {
        listen       127.0.0.1:8080 http2 ssl;
        server_name  localhost;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        location / {
            proxy_pass   http://127.0.0.1:8081;
            proxy_cache  NAME;
            proxy_http_version 1.1;
            proxy_cache_revalidate on;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            proxy_pass             http://127.0.0.1:8082;
            proxy_cache            NAME;
            proxy_http_version     1.1;
            proxy_cache_revalidate on;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        location / {
            add_header Cache-Control s-maxage=$arg_ttl;
            limit_rate $rate;
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

my ($path, $sid, $frames, $frame, $t1, $resident_time);

# normal origin

wait_for_second_boundary();

$path = '/t.html?ttl=2';

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 0, 'age');

select undef, undef, undef, 2.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 2, 'age');

select undef, undef, undef, 1.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 0, 'age');

# normal origin (crossing second boundary)

wait_for_just_before_second_boundary();

$path = '/t.html?ttl=3';

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 1, 'age');

select undef, undef, undef, 2.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 3, 'age');

select undef, undef, undef, 2.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 0, 'age');

# slow origin

wait_for_second_boundary();

$path = '/t.html?ttl=6&slow=1';

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 4, 'age');

select undef, undef, undef, 2.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 6, 'age');

select undef, undef, undef, 1.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 5, 'age');

# update age after restart

$path = '/t.html?ttl=20';

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 0, 'age');
$t1 = time();

$t->stop();

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

$resident_time = time() - $t1;

$s = getconn(port(8080));
ok($s, 'ssl connection');

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, $resident_time, 'age');

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

sub wait_for_second_boundary {
    my $now = Time::HiRes::time();
    my $next_second = POSIX::ceil($now);
    my $sleep = $next_second - $now;
    select undef, undef, undef, $sleep;
}

sub wait_for_just_before_second_boundary {
    my $now = Time::HiRes::time();
    my $next_second = POSIX::ceil($now);
    my $sleep = $next_second - 0.001 - $now;
    # select undef, undef, undef, $sleep;
    Time::HiRes::usleep($sleep * 1000 * 1000);
}

###############################################################################
