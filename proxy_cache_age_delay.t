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

my $t = Test::Nginx->new()->has(qw/http proxy cache perl/)->plan(2)
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

        gzip on;
        gzip_min_length 0;

        location / {
            proxy_pass    http://127.0.0.1:8081;

            proxy_cache   NAME;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }
    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            perl 'sub {
                my $r = shift;
                my %args = map { split(/=/, $_, 2) } split(/&/, $r->args);
                my $age = $args{"age"};
                if (exists $args{"delay"}) {
                    $r->variable("age", $age);
                    $r->sleep($args{"delay"}, \&next);
                } else {
                    $r->header_out("Cache-Control", "max-age=5");
                    $r->header_out("Age", $age) if $age;
                    $r->send_http_header("text/plain");
                    return OK if $r->header_only;
                    $r->print("TEST");
                }
                return OK;

                sub next {
                    my $r = shift;
                    my $age = $r->variable("age");
                    $r->header_out("Cache-Control", "max-age=5");
                    $r->header_out("Age", $age) if $age;
                    $r->send_http_header("text/plain");
                    return OK if $r->header_only;
                    $r->print("TEST");
                    return OK;
                }
            }';
        }
    }
}

EOF

$t->run();

###############################################################################

my $res = http_get('/?delay=1000&age=1');
printf(STDERR "res=\n%s\n", $res);
like($res,
     qr/\r\nAge: 1\r\n.*\r\nX-Cache-Status: MISS\r\n/s,
     'with origin age and response delay');

my $res2 = http_get('/?delay=1000&age=1');
printf(STDERR "res=\n%s\n", $res2);
like($res2,
    qr/\r\nAge: 2\r\n.*\r\nX-Cache-Status: HIT\r\n/s,
    'with origin age and response delay');

###############################################################################
