#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Hiroaki Nakamura

# Tests for age in http proxy cache.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

use POSIX qw/ ceil /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(8)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=NAME:1m;
    proxy_cache_path   %%TESTDIR%%/cache2  levels=1:2
                       keys_zone=NAME2:1m;

    map $arg_slow $rate {
        default 8k;
        1       100;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass             http://127.0.0.1:8081;
            proxy_cache            NAME;
            proxy_http_version     1.1;
            proxy_cache_revalidate on;
            add_header parent_date $upstream_http_date;
            add_header child_msec $msec;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            proxy_pass             http://127.0.0.1:8082;
            proxy_cache            NAME2;
            proxy_http_version     1.1;
            proxy_cache_revalidate on;
            add_header origin_date $upstream_http_date;
            add_header parent_msec $msec;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        location / {
            add_header Cache-Control $http_x_cache_control;
            limit_rate $rate;
            add_header origin_msec $msec;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');
$t->write_file('t2.html', 'SEE-THIS');
$t->write_file('t3.html', 'SEE-THIS');

$t->run();

###############################################################################

# normal origin

wait_until_next_second();

like(get('/t.html', 's-maxage=2'), qr/\r\nAge: 0\r\n/, 'age first');

sleep 2;

like(get('/t.html', 's-maxage=2'), qr/\r\nAge: 2\r\n/, 'age hit');

sleep 1;

like(http_get('/t.html'), qr/\r\nAge: 0\r\n/, 'age updated');

# slow origin

SKIP: {
skip 'no exec on win32', 3 if $^O eq 'MSWin32';

wait_until_next_second();

like(get('/t2.html?slow=1', 's-maxage=6'), qr/\r\nAge: 4\r\n/,
    'slow origin first');

sleep 2;

like(http_get('/t2.html?slow=1'), qr/\r\nAge: 6\r\n/, 'slow origin hit');

sleep 1;

like(http_get('/t2.html?slow=1'), qr/\r\nAge: 5\r\n/, 'slow origin updated');

}

# update age after restart

wait_until_next_second();

like(get('/t3.html', 's-maxage=20'), qr/\r\nAge: 0\r\n/, 'age before restart');
my $t1 = time();

$t->stop();

$t->run();

my $resident_time = time() - $t1;
like(http_get('/t3.html'), qr/\r\nAge: $resident_time\r\n/,
    'age after restart');

$t->stop();

###############################################################################

sub get {
	my ($url, $extra, %extra) = @_;
	return http(<<EOF, %extra);
GET $url HTTP/1.1
Host: localhost
Connection: close
X-Cache-Control: $extra

EOF
}

# Wait until the next second boundary.
# Calling this before sending a request increases the likelihood that the
# timestamp value does not cross into the next second while sending a request
# and receiving a response.
sub wait_until_next_second {
    my $now = time();
    my $next_second = ceil($now);
    my $sleep = $next_second - $now;
    select undef, undef, undef, $sleep;
}

###############################################################################
