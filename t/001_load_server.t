#!/usr/bin/env perl

use lib qw/./;

use Test::More;
use Test::Exception;
use POE;
use Data::Dumper;

plan tests => 14;

BEGIN { use_ok('POE::Component::Server::XMLRPC') }
my $xs;

$poe_kernel->run(); # silence the 'kernel not run' warning.

# constructor tests
throws_ok( sub { $xs = POE::Component::Server::XMLRPC->new() },
           qr/Attribute \(name\) is required/, 'throws: name required');

lives_ok( sub { $xs = POE::Component::Server::XMLRPC->new(name => 'bob') },
          'creating object');

is($xs->name, 'bob', 'get name');

# port attr tests.
is($xs->port, 80, 'default port');
throws_ok( sub { $xs->port(12345) }, qr/read-only/, 'throws: port is ro');

lives_ok(sub {
             $xs = POE::Component::Server::XMLRPC->new(name => 'bob', port => 12345)
            }, 'create with port');
is($xs->port, 12345, 'non-default port');

throws_ok( sub {
               POE::Component::Server::XMLRPC->new(name => 'bob',
                                                   port => -100);
               }, qr/port is not in the range/, 'throws: invalid negative port');

throws_ok( sub {
               POE::Component::Server::XMLRPC->new(name => 'bob',
                                                   port => 65555);
               }, qr/port is not in the range/, 'throws: invalid highnum port');

# kernel attr
isa_ok($xs->kernel, 'POE::Kernel', 'kernel attr');
lives_ok(sub { $xs->kernel->post(foo => 'bar') }, 'posting via kernel attr');

#  debug attr

is($xs->debug, 0, 'debug false by default');
ok($xs->debug(1), 'set debug');
$xs->debug(0);

done_testing;

