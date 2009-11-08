#!/usr/bin/env perl

use lib qw/./;

use Test::More;
use Test::Exception;
use POE;

plan tests => 13;

BEGIN { use_ok('POE::Component::Client::XMLRPC') }
my $xc;

$poe_kernel->run(); # silence the 'kernel not run' warning.

throws_ok( sub { $xc = POE::Component::Client::XMLRPC->new() },
           qr/Attribute \(name\) is required/, 'throws: name required');

lives_ok( sub { $xc = POE::Component::Client::XMLRPC->new(name => 'bob') },
          'creating object');

is($xc->name, 'bob', 'set name');

# test uri setting.

is($xc->uri, undef, "initialised with empty uri");

is($xc->uri('http://example.com/'), 'http://example.com/', 'set uri by string');

is($xc->uri('http://example.com'), 'http://example.com/RPC2',
   'set uri has implicit RPC2');

throws_ok( sub { $xc->uri('fdahjilfdak') }, qr/Validation failed/,
           'throws: invalid uri');

ok($xc->uri(new URI 'http://foo.bar:1234/?what#foo'), 'set uri by URI obj');

# test debug attribute.

is($xc->debug, 0, 'debug false by default');
ok($xc->debug(1), 'set debug');
$xc->debug(0);

# kernel
isa_ok($xc->kernel, 'POE::Kernel', 'kernel attr');
lives_ok(sub { $xc->kernel->post(foo => 'bar') }, 'posting via kernel attr');

done_testing;

