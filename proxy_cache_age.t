#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for http proxy cache revalidation with conditional requests.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache rewrite/)->plan(7)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=one:1m;

    proxy_cache_revalidate on;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass    http://127.0.0.1:8081;
            proxy_cache   one;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            add_header Last-Modified "Mon, 02 Mar 2015 17:20:58 GMT";
            add_header Age $http_x_age;
            add_header Cache-Control "max-age=5";
            add_header X-If-Modified-Since $http_if_modified_since;
            add_header X-If-None-Match $http_if_none_match;
        }
    }
}

EOF

my $d = $t->testdir();

$t->write_file('t', 'SEE-THIS');
$t->write_file('t2', 'SEE-THIS');

$t->run();

###############################################################################

# request documents and make sure they are cached

Test::Nginx->wait_for_non_flakey_test_start_timing();

like(http_get('/t'), qr/^X-Cache-Status: MISS.*SEE/ms, 'request /t');
select undef, undef, undef, 4.0;
like(http_get('/t'), qr/^Age: 4\r\n.*^X-Cache-Status: HIT.*SEE/ms, 'request /t cached');
select undef, undef, undef, 2.0;
like(http_get('/t'), qr/^X-Cache-Status: EXPIRED.*SEE/ms, 'cache /t expired');
select undef, undef, undef, 1.0;
like(http_get('/t'), qr/^Age: 1\r\n.*^^X-Cache-Status: HIT.*SEE/ms, 'cache /t validated');

like(get('/t2', 'X-Age: 1'), qr/^Age: 1\r\n.*^X-Cache-Status: MISS.*SEE/ms, 'request /t2');
select undef, undef, undef, 3.0;
like(http_get('/t2'), qr/^Age: 4\r\n.*^X-Cache-Status: HIT.*SEE/ms, 'cache /t2');
select undef, undef, undef, 2.0;
like(http_get('/t2'), qr/^X-Cache-Status: EXPIRED.*SEE/ms, 'cache /t2 expired');

###############################################################################

sub get {
	my ($url, $extra) = @_;
	return http(<<EOF);
GET $url HTTP/1.1
Host: localhost
Connection: close
$extra

EOF
}

###############################################################################
