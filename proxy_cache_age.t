#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for http proxy cache.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT :gzip /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache gzip/)->plan(30)
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
        1       200;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        gzip on;
        gzip_min_length 0;

        location / {
            proxy_pass    http://127.0.0.1:8081;
            proxy_cache   NAME;
            proxy_cache_valid 1m;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            limit_rate $rate;
            add_header Age $arg_age;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');

$t->run();

###############################################################################

test_age('/t.html', undef, 0, 2);
my $t1 = time();

test_age('/t.html?age=1', 1, 1, 3);
test_age('/t.html?slow=1', undef, 1, 3);
test_age('/t.html?age=1&slow=1', 1, 2, 4);

$t->stop();

$t->run();

my $rt1 = time() - $t1; # resident time
test_age('/t.html', $rt1 + 2, $rt1 + 2, $rt1 + 4);

$t->stop();

###############################################################################

sub test_age {
    my ($path, $age1, $age2, $age3) = @_;

    my ($res, $sid, $frames, $frame);

    $res = http_get($path);
    like($res, qr/^HTTP\/1.1 200 /, 'status');
    if (defined($age1)) {
        like($res, qr/\r\nAge: $age1\r\n/, 'age');
    } else {
        unlike($res, qr/\r\nAge: /, 'age');
    }

    $res = http_get($path);
    like($res, qr/^HTTP\/1.1 200 /, 'status');
    like($res, qr/\r\nAge: $age2\r\n/, 'age');

    select undef, undef, undef, 2.0;

    $res = http_get($path);
    like($res, qr/^HTTP\/1.1 200 /, 'status');
    like($res, qr/\r\nAge: $age3\r\n/, 'age');
}

###############################################################################
