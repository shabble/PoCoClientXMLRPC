#!/usr/bin/env perl

use strict;
use warnings;

use lib qw/./;

use Test::More;
use Test::Exception;

#sub POE::Kernel::TRACE_SESSIONS() { 1 }
#sub POE::Kernel::TRACE_REFCNT() { 1 }
use POE;

use POE::Component::Client::XMLRPC;
use POE::Component::Server::XMLRPC;
use Data::Dumper;
use POE::Component::Server::HTTP; # for exports of RC_

my $debug = $ENV{PERL_DEBUG} // 0;

#TODO: abstract this out so different broken requests can be sent.
#TODO: test all things that server verifies against.
#TODO: test if responder can take some time.
#TODO: test timeouts


create_server();
create_client()->uri('http://localhost:12345/?session=serv_session');


create_server_session();
create_client_session();

$poe_kernel->run;

# test different session_mapping regexes.
diag 'testing alternate session mapping' if $debug;

create_server(session_mapping => qr|^/(.+)$|);
create_client()->uri('http://localhost:12345/serv_session');


create_server_session();
create_client_session();

$poe_kernel->run;

create_server(session_mapping => qr|^/(.+)$|);
create_client()->uri('http://localhost:12345/?session=serv_session');


create_server_session();
create_client_session(on_fault => sub {
                          my $arg = shift;
                          is($arg->{faultCode}, 502);
                          like($arg->{faultString},
                               qr/Session identifier .*? not valid/);
                      });

$poe_kernel->run;

# don't register handler.
create_server();
create_client()->uri('http://localhost:12345/?session=serv_session');


create_server_session(handlers => []);
create_client_session(on_fault => sub {
                          my $arg = shift;
                          is($arg->{faultCode}, 502);
                          like($arg->{faultString},
                               qr/Session identifier .*? not valid/);
                      });

$poe_kernel->run;

# rescind handler before calling
create_server();
create_client()->uri('http://localhost:12345/?session=serv_session');


create_server_session(on_setup => sub {
                          $poe_kernel->post(xr_server => rescind
                                            => serv_session
                                            => 'handler1');
                      },
                     );

create_client_session(on_fault => sub {
                          my $arg = shift;
                          is($arg->{faultCode}, 403);
                          like($arg->{faultString},
                               qr/Invalid methodName/);
                      });

$poe_kernel->run;

# handler that doesn't respond
diag("timeouts") if $debug;
create_server(debug => $debug);

my $x = create_client(timeout => 0.5);
$x->uri('http://localhost:12345/?session=serv_session');
diag($x->timeout) if $debug;

create_server_session(states => {
                                 sleepy => sub {
                                   my $t = $_[ARG0];
                                   diag("returning pending response RC_WAIT") if $debug;
                                   $t->return(RC_WAIT);

                                 }
                                },
                      handlers => ['sleepy']
                                 );

create_client_session(on_fault => sub {
                          my $arg = shift;
                          is($arg->{faultCode}, 408, 'got timeout response');
                          like($arg->{faultString},
                               qr/timed out/);
                      },
                      call => 'sleepy');

$poe_kernel->run;


# send a fault from within a handler.
create_server(debug => $debug);

$x = create_client(timeout => 0.5);
$x->uri('http://localhost:12345/?session=serv_session');
diag($x->timeout) if $debug;

create_server_session(states => {
                                 faulty => sub {
                                     my $t = $_[ARG0];
                                     $t->fault(402,
                                               'Payment Required',
                                               'you cheapskate');
                                 }
                                },
                      handlers => ['faulty']
                                 );

create_client_session(on_fault => sub {
                          my $arg = shift;
                          is($arg->{faultCode}, 402, 'Got payment required error');
                          like($arg->{faultString},
                               qr/Payment Required/);
                      },
                      call => 'faulty');

$poe_kernel->run;

my @test_args_sets = ("Hello",
                      [1, 2, 3],
                      ['hi', 1, 2],
                      # TODO: why does htis fail
                      # {hey => 'joe', "\x01" => 55}
                      {hey => 'joe', some => 10},
                     );

subtest 'Test echo handler' => sub {
    plan tests => scalar(@test_args_sets) * 11;

    foreach my $set (@test_args_sets) {

        create_server();
        create_client()->uri('http://localhost:12345/?session=serv_session');


        create_server_session(states => { echo =>
                                          sub {
                                              my $t = $_[ARG0];
                                              $t->return($t->params);
                                          },
                                        },
                              handlers => ['echo']
                             );
        create_client_session(call => 'echo',
                              args => [$set],
                              on_response =>
                              sub { is_deeply([$set], shift) },
                              on_fault => sub { fail('unexpected fault') },
                             );

        $poe_kernel->run;
    }
};

done_testing;

sub create_server_session {
    my $options = { @_ };
    $options->{handlers} = ['handler1'] unless exists $options->{handlers};
    $options->{states} = {} unless exists $options->{states};
    POE::Session->create
        (
         inline_states => {
                           _start => sub {
                               $poe_kernel->alias_set('serv_session');
                               $poe_kernel->yield('setup');
                           },
                           setup => sub {
                               foreach my $handler (@{$options->{handlers}}) {
                                   ok(post(xr_server
                                        => publish
                                        => serv_session
                                        => $handler), 'register handler');
                                   $options->{on_setup}->()
                                     if exists $options->{on_setup};
                               }
                           },
                           handler1 => sub {
                               my $t = $_[ARG0];
                               $t->return('ok');
                           },
                           shutdown => sub {
                               diag("Server session shutdown event") if $debug;
                               foreach my $h (@{$options->{handlers}}) {
                                   post(xr_server
                                        => rescind
                                        => serv_session
                                        => $h);
                               }
                               post(xr_server
                                    => 'shutdown');
                               $poe_kernel->alias_remove('serv_session');
                           },
                           _stop => sub {
                               print 'serv_session stopping', $/ if $debug;
                           },
                           %{ $options->{states} },
                          },
        );
}

sub create_client_session {
    my $options = { @_ };
    $options->{states} = {} unless exists $options->{states};
    POE::Session->create
        (
         inline_states => {
                           _start => sub {
                               $poe_kernel->alias_set('client_session');
                               $poe_kernel->yield('setup');
                           },
                           setup => sub {
                               # TODO: start a timer to kill it all eventually.
                               ok(post(xr_client
                                       => xmlrpc_call
                                       => response
                                       => fault
                                       => $options->{call} // 'handler1'
                                       => $options->{args} // ['']),
                                  'posting xmlrpc call');
                           },
                           response => sub {
                               my $arg = $_[ARG0];
                               if ($options->{on_response}) {
                                   $options->{on_response}->($arg, @_);
                               } else {
                                   diag("Got response:\n". Dumper($arg).$/) if $debug;
                               }
                               $poe_kernel->yield('shutdown');
                           },
                           fault => sub {
                               my $arg = $_[ARG0];
                               if ($options->{on_fault}) {
                                   $options->{on_fault}->($arg, @_);
                               } else {
                                   diag("Got fault:\n". Dumper($arg).$/) if $debug;
                               }

                               $poe_kernel->yield('shutdown');
                           },
                           shutdown => sub {
                               diag("Client Shutdown event") if $debug;
                               post(serv_session => 'shutdown');
                               post(xr_client => 'shutdown');
                               $poe_kernel->alias_remove('client_session');
                           },
                           _stop => sub {
                               print 'client_session stopping', $/ if $debug;
                           },
                           %{ $options->{states} },
                          },
        );
}


sub create_server {
    my $ret = POE::Component::Server::XMLRPC->new(debug => $debug,
                                        name => 'xr_server',
                                        port => 12345, @_);
    isa_ok($ret, 'POE::Component::Server::XMLRPC');
    return $ret;
}
sub create_client {
    my $ret = POE::Component::Client::XMLRPC->new(name => 'xr_client',
                                                  debug => $debug,
                                                  @_);
    isa_ok($ret, 'POE::Component::Client::XMLRPC');
    return $ret;
}


sub post {
    my $post_ret = $poe_kernel->post(@_);
    if (!$post_ret) {
        fail("post with args ".join(":", @_)." failed, $!");
    } else {
        pass("post with args ".join(":", @_));
    }
}
