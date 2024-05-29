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

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(11)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=NAME:1m;

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

$t->write_file('t.html', 'SEE-THIS');

$t->run();

###############################################################################

my ($res, $t1, $resident_time);

# normal origin

wait_for_second_boundary();

$res = http_get('/t.html?ttl=2');
like($res, qr/\r\nAge: 0\r\n/, 'age');

select undef, undef, undef, 2.0;

$res = http_get('/t.html?ttl=2');
like($res, qr/\r\nAge: 2\r\n/, 'age');

select undef, undef, undef, 1.0;

$res = http_get('/t.html?ttl=2');
like($res, qr/\r\nAge: 0\r\n/, 'age');

# normal origin (crossing second boundary)

wait_for_just_before_second_boundary();

$res = http_get('/t.html?ttl=3');
like($res, qr/\r\nAge: 1\r\n/, 'age');

select undef, undef, undef, 2.0;

$res = http_get('/t.html?ttl=3');
like($res, qr/\r\nAge: 3\r\n/, 'age');

select undef, undef, undef, 2.0;

$res = http_get('/t.html?ttl=3');
like($res, qr/\r\nAge: 0\r\n/, 'age');

# slow origin

wait_for_second_boundary();

$res = http_get('/t.html?ttl=6&slow=1');
like($res, qr/\r\nAge: 4\r\n/, 'age');

select undef, undef, undef, 2.0;

$res = http_get('/t.html?ttl=6&slow=1');
like($res, qr/\r\nAge: 6\r\n/, 'age');

select undef, undef, undef, 1.0;

$res = http_get('/t.html?ttl=6&slow=1');
like($res, qr/\r\nAge: 5\r\n/, 'age');

# update age after restart

$res = http_get('/t.html?ttl=20');
like($res, qr/\r\nAge: 0\r\n/, 'age');
$t1 = time();

$t->stop();

$t->run();

$resident_time = time() - $t1;
$res = http_get('/t.html?ttl=20');
like($res, qr/\r\nAge: $resident_time\r\n/, 'age');

$t->stop();

###############################################################################

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
    Time::HiRes::usleep($sleep * 1000 * 1000);
}

###############################################################################
