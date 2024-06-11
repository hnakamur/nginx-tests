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
use POSIX;
use Time::HiRes;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache gzip perl/)->plan(42)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;
        access_log   %%TESTDIR%%/access8080.log;
        error_log    %%TESTDIR%%/error8080.log;

        gzip on;
        gzip_min_length 0;

        location / {
            proxy_pass             http://127.0.0.1:8081;
            proxy_cache            NAME;
            proxy_http_version     1.1;
            proxy_cache_revalidate on;
            add_header X-Parent-Date $upstream_http_date;
            add_header X-Child-Cache $upstream_cache_status;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;
        access_log   %%TESTDIR%%/access8081.log;
        error_log    %%TESTDIR%%/error8081.log;

        location /delay {
            perl 'sub {
                my $r = shift;
                my %args = map { split(/=/, $_, 2) } split(/&/, $r->args);
                if (exists $args{"delay"}) {
                    $r->sleep($args{"delay"} * 1000, \&next);
                } else {
                    next($r);
                }
                return OK;

                sub next {
                    my $r = shift;
                    $r->internal_redirect(substr($r->uri, length("/delay")));
                    return OK;
                }
            }';
        }

        location / {
            add_header Cache-Control max-age=5;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');

$t->run();

###############################################################################

sub wait_for_second_boundary() {
    my $now = Time::HiRes::time();
    my $next_second = POSIX::ceil($now);
    my $sleep = $next_second - $now;
    select undef, undef, undef, $sleep if $sleep < 0.9;
}

sub test_age {
    my ($line, $url, $age1, $age2, $sleep, $age3) = @_;

    my ($prefix, $res, $sid, $frames, $frame);

    wait_for_second_boundary();
    $prefix = 'test_age from line ' . $line . ': ';
    $res = http_get($url);
    like($res, qr/^HTTP\/1.1 200 /, $prefix . 'res1 status');
    if (defined($age1)) {
        like($res, qr/\r\nAge: $age1\r\n/, $prefix . 'res1 age');
    } else {
        unlike($res, qr/\r\nAge: /, $prefix . 'res1 age');
    }

    $res = http_get($url);
    like($res, qr/^HTTP\/1.1 200 /, $prefix . 'res2 status');
    like($res, qr/\r\nAge: $age2\r\n/, $prefix . 'res2 age');

    select undef, undef, undef, $sleep;

    $res = http_get($url);
    like($res, qr/^HTTP\/1.1 200 /, $prefix . 'res3 status');
    like($res, qr/\r\nAge: $age3\r\n/, $prefix . 'res3 age');
}

###############################################################################

test_age(__LINE__, '/delay/t.html?delay=0', 0, 0, 2.0, 2);
test_age(__LINE__, '/delay/t.html?delay=2', 2, 2, 2.0, 4);
my $t1 = time();

# test_age(__LINE__, '/t.html?ttl=60&slow2=1', 2, 2, 2.0, 4);
# test_age(__LINE__, '/t.html?ttl=60&slow=1&slow2=1', 4, 4, 2.0, 6);

$t->stop();

$t->run();

# my $rt1 = time() - $t1; # resident time
# test_age(__LINE__, '/t.html?ttl=60', $rt1 + 3, $rt1 + 3, 2.0, $rt1 + 5);

# # conditional requests

# test_age(__LINE__, '/t.html?ttl=1', 0, 0, 2.0, 0);
# test_age(__LINE__, '/t.html?ttl=2&slow=1', 3, 2, 2.0, 2);
# test_age(__LINE__, '/t.html?ttl=2&slow=1&slow2=1', 4, 2, 2.0, 2);

$t->stop();

###############################################################################
