#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for HTTP/3 with proxy module.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v3 proxy cryptx/)
	->has_daemon('openssl')->plan(6)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    log_format test $uri:$status:$request_completion;

    proxy_cache_path %%TESTDIR%%/cache    keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        listen       127.0.0.1:8081;
        server_name  localhost;

        access_log %%TESTDIR%%/test.log test;

        location /cache {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache NAME;
            proxy_cache_valid 1m;
        }

        location / { }
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

my $content = 'SEE-THIS';
$t->write_file('t.html', $content);
$t->run();

###############################################################################

my ($s, $sid, $frames, $frame);

my $re = qr/nginx\/\d+\.\d+\.\d+/;

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ path => '/cache/t.html' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200, 'status#1');
like($frame->{headers}->{'server'}, qr/^$re$/, 'server#1');
is($frame->{headers}->{'content-length'}, length($content), 'content-length#1');
is($frame->{headers}->{'age'}, undef, 'age#1');

$sid = $s->new_stream({ path => '/cache/t.html' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 0, 'age#2');

select undef, undef, undef, 2.0;

$sid = $s->new_stream({ path => '/cache/t.html' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 2, 'age#3');

$t->stop();

###############################################################################
