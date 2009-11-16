# $Id: XMLRPC.pm,v 1.4 2003/03/20 23:26:02 mah Exp $
# License and documentation are after __END__.

package POE::Component::Server::XMLRPC;

use strict;
use warnings;

use Carp qw(croak cluck);
use vars qw($VERSION);
$VERSION = '0.07';

use MooseX::POE; #with qw/MooseX::POE::Aliased/;
use Moose::Util::TypeConstraints;

use POE::Component::Server::HTTP;
use XMLRPC::Lite;
use Data::Dumper;

has 'kernel' =>
  (
   is      => 'ro',
   isa     => 'POE::Kernel',
   default => sub { $POE::Kernel::poe_kernel },
   handles => { post => 'post', call => 'call' },
  );

has 'name' =>
  (
   is       => 'ro',
   isa      => 'Str',
   required => 1,
  );

has 'http_transport' =>
  (
   is       => 'ro',
   #traits   => ['Hash'],
   isa      => 'HashRef[Str]', # aliases for the transport
   required => 1,
   lazy     => 1,
   builder  => '_create_http_transport',
  );

has 'public_interfaces' =>
  (
   is       => 'ro',
   writer   => '_set_public_interfaces',
   traits => ['Hash'],
   isa      => 'HashRef[Str]',
   required => 1,
   lazy     => 1,
   default  => sub { {} },
   handles => {
               is_valid_session => 'exists'
              },
   #             add_interface => 'set',
   #             del_
  );

subtype 'PortNum'
  => as 'Int'
  => where { $_ > 04 && $_ < 65536 }
  => message { "Value $_ for port is not in the range 1024--65536" };

has 'port' =>
  (
   is       => 'ro',
   isa      => 'PortNum',
   required => 1,
   lazy     => 1,
   default  => sub { 80 },
  );

has 'debug' =>
  (
   is       => 'rw',
   isa      => 'Bool',
   required => 1,
   lazy     => 1,
   default  => sub { 0 },
  );

has 'session_mapping' =>
  (
   is       => 'rw',
   isa      => 'RegexpRef',
   required => 1,
   lazy     => 1,
   default  => sub { qr|^/\?session=(.+)$| }
  );

sub START {
    my ($self) = $_[OBJECT];
    $self->kernel->alias_set($self->name);

    # instantiate the (lazy) http_transport via builder.
    $self->http_transport;

    print STDERR "[", $self->get_session_id, "] server starting up: ", $self->name, "\n" if $self->debug;
}

sub STOP {
    my ($self) = $_[OBJECT];
    print STDERR $self->name, " is stopping\n" if $self->debug;
}

sub _create_http_transport {
    my $self = shift;
    my $aliases = POE::Component::Server::HTTP->new
      ( Port     => $self->port,
        Headers  =>
        { Server => "POE::Component::Server::XMLRPC/$VERSION",
        },
        ContentHandler => { "/"
                            => sub {
                                $poe_kernel->call($self->name,
                                                  'request_handler',
                                                  @_);
                            }
                          },
      );
    return $aliases;
}

event 'publish' => sub {
    my ($self, $alias, $event) = @_[OBJECT, ARG0, ARG1];
    #TODO: validate alias and event somehow?
    print STDERR "registering $alias:$event\n" if $self->debug;
    my $ref = $self->public_interfaces;
    $ref->{$alias}->{$event} = 1;
};

event 'rescind' => sub {
    my ($self, $alias, $event) = @_[OBJECT, ARG0, ARG1];
    my $ref = $self->public_interfaces;
    if (exists $ref->{$alias}->{$event}) {
        print STDERR "unregistering $alias:$event\n" if $self->debug;
        delete $ref->{$alias}->{$event};
    } else {
        print STDERR "Rescinding unregistered handler: $alias : $event"
          if $self->debug;
    }
};

event 'shutdown' => sub {
    my ($self) = $_[OBJECT];
    print STDERR "shutting down " . __PACKAGE__ . "\n" if $self->debug;

    my $ret = 0;
    print STDERR "calling shutdown on ", $self->http_transport->{httpd}, $/
      if $self->debug;
    $ret = $self->kernel->call($self->http_transport->{httpd}, 'shutdown');
    if ($ret) {
        cluck "http shutdown failed: $ret: $!\n";
    }
    $ret = $self->kernel->call($self->http_transport->{tcp},   'shutdown');
    if ($ret) {
        cluck "tcp shutdown failed: $ret: $!\n";
    }
    $ret = $self->kernel->alias_remove($self->name);
    if ($ret) {
        cluck "alias remove failed: $ret: $!\n";
    }

};


event 'request_handler' => sub {
    my ($self, $req, $resp) = @_[OBJECT, ARG0, ARG1];

    # eww. see comments in PoCo::Server::HTTP about keepalives.
    $req->header(Connection => 'close');

    my $validated_request = $self->_validate_request($req);

    unless ($validated_request->[0] == 200) {
        return build_fault_response($resp, @{$validated_request});
    }

    my $target_session = $validated_request->[1];

    my ($data, $method_name, $args);

    # Deserialise the XML payload.
    eval {
        $data        = XMLRPC::Deserializer->deserialize($req->content);
        $method_name = $data->valueof("methodName");
        $args        = $data->valueof("params");
    };
    if ($@) {
        return
          build_fault_response($resp,
                               500,
                               "XML Parsing Exception",
                               "An exception fired while parsing the request: $@");
      }

    # validate method name.
    return build_fault_response($resp, 403, 'Bad Request', 'methodName is required')
      unless defined $method_name && length $method_name;


    my $methods_for_session = $self->public_interfaces->{$target_session};
    unless (exists($methods_for_session->{$method_name})) {
        return build_fault_response($resp,
                               403,
                               'Bad Request',
                               "Invalid methodName: $method_name");
    }

    eval {
        XMLRPCTransaction->start($resp, $target_session, $method_name, $args);
    };

    if ($@) {
        return build_fault_response($resp,
                                    500,
                                    "Application Fault",
                                    "An exception occurred "
                                    . "while dispatching the request: $@",
                                   );
    }

    # return and allow the handler to deal with the response directly.
    return RC_WAIT;
};

sub _validate_request {
    my ($self, $request) = @_;

    return [400, "Bad Request", "Content-Type must be text/xml"]
      unless $request->headers->content_is_xml;

    return [400, 'Bad Request', "Content-Length header does not match actual length"]
      unless $request->headers->content_length == length $request->content;

    return [405, "Method Not Allowed", "XMLRPC requires a HTTP POST request"]
      unless $request->method eq 'POST';

    my $query = $request->uri->path_query;
    if ($query =~ $self->session_mapping && length $1) {
        my $target_session = $1;
        if ($self->is_valid_session($target_session)) {
            return [200, $target_session];
        } else {
            return [502, 'Bad Gateway',
                    "Session identifier $target_session is not valid"];
        }
    } else {
        return [502, 'Bad Gateway',
                "Unable to parse session identifier from request path"];
    }
}

sub build_fault_response {
  my ($response, $fault_code, $fault_string, $result_description) = @_;

  $fault_code ||= 500;
  $fault_string ||= "Unknown Fault";
  $result_description ||= "Unknown cause";

  my $response_content
    = XMLRPC::Serializer
      ->envelope('fault', $fault_code, "$fault_string: $result_description");

  $response->code(200);
  $response->header("Content-Type", "text/xml");
  $response->header("Content-Length", length($response_content));
  $response->content($response_content);

  return RC_OK;
}


no MooseX::POE;
no Moose::Util::TypeConstraints;
__PACKAGE__->meta->make_immutable;

package XMLRPCTransaction;

use strict;
use warnings;

sub TR_RESPONSE () { 0 }
sub TR_SESSION  () { 1 }
sub TR_EVENT    () { 2 }
sub TR_ARGS     () { 3 }

sub start {
  my ($type, $response, $session, $event, $args) = @_;

  my $self = bless
    [ $response,
      $session,
      $event,
      $args,
    ], $type;

  $POE::Kernel::poe_kernel->post($session, $event, $self);
  undef;
}

sub params {
  my $self = shift;
  return $self->[TR_ARGS];
}

sub fault {
  my ($self, $code, $msg, $desc) = @_;

  my $response = $self->[TR_RESPONSE];
  POE::Component::Server::XMLRPC::build_fault_response($response, $code, $msg, $desc);
  $response->continue();

}

sub return {
  my ($self, $retval) = @_;

  my $content = XMLRPC::Serializer->envelope(response => 'toMethod', $retval);
  my $response = $self->[TR_RESPONSE];

  $response->code(200);
  $response->header("Content-Type", "text/xml");
  $response->header("Content-Length", length $content );
  $response->content($content);
  $response->continue();
}

1;

__END__

=head1 NAME

POE::Component::Server::XMLRPC - publish POE event handlers via XMLRPC over HTTP

=head1 SYNOPSIS

  use POE;
  use POE::Component::Server::XMLRPC;

  POE::Component::Server::XMLRPC->new( alias => "xmlrpc", port  => 32080 );

  POE::Session->create
    ( inline_states =>
      { _start => \&setup_service,
        _stop  => \&shutdown_service,
        sum_things => \&do_sum,
      }
    );

  $poe_kernel->run;
  exit 0;

  sub setup_service {
    my $kernel = $_[KERNEL];
    $kernel->alias_set("service");
    $kernel->post( xmlrpc => publish => service => "sum_things" );
  }

  sub shutdown_service {
    $_[KERNEL]->post( xmlrpc => rescind => service => "sum_things" );
  }

  sub do_sum {
    my $transaction = $_[ARG0];
    my $params = $transaction->params();
    my $sum = 0;
    for(@{$params}) {
      $sum += $_;
    }
    $transaction->return("Thanks.  Sum is: $sum");
  }

=head1 DESCRIPTION

POE::Component::Server::XMLRPC is a bolt-on component that can publish a
event handlers via XMLRPC over HTTP.

There are four steps to enabling your programs to support XMLRPC
requests.  First you must load the component.  Then you must
instantiate it.  Each POE::Component::Server::XMLRPC instance requires
an alias to accept messages with and a port to bind itself to.
Finally, your program should posts a "publish" events to the server
for each event handler it wishes to expose.

  use POE::Component::Server::XMLRPC
  POE::Component::Server::XMLRPC->new( alias => "xmlrpc", port  => 32080 );
  $kernel->post( xmlrpc => publish => session_alias => "methodName" );

Later you can make events private again.

  $kernel->post( xmlrpc => rescind => session_alias => "methodName" );

Finally you must write the XMLRPC request handler.  XMLRPC
handlers receive a single parameter, ARG0, which contains a
XMLRPC transaction object.  The object has two methods: params(),
which returns a reference to the XMLRPC parameters; and return(),
which returns its parameters to the client as a XMLRPC response.

  sum_things => sub {
    my $transaction = $_[ARG0];
    my $params = $transaction->params();
    my $sum = 0;
    while (@{$params})
      $sum += $value;
    }
    $transaction->return("Thanks.  Sum is: $sum");
  }

And here is a sample XMLRPC::Lite client.  It should work with the
server in the SYNOPSIS.

  #!/usr/bin/perl

  use warnings;
  use strict;

  use XMLRPC::Lite;

  print XMLRPC::Lite
    -> proxy('http://poe.dynodns.net:32080/?session=sum_server')
    -> sum_things(8,6,7,5,3,0,9)
    -> result
    ;
  pring "\n";

=head1 BUGS

This project is a modified version of POE::Component::Server::SOAP by
Rocco Caputo.  Of that, he writes:

  This project was created over the course of two days, which attests
  to the ease of writing new POE components.  However, I did not learn
  XMLRPC in depth, so I am probably not doing things the best they
  could.

Thanks to his code, I've managed to create this module in one day (on
only my second day of using POE).  There's gotta be bugs here.  Please
use http://rt.cpan.org/ to report them.

=head1 SEE ALSO

The examples directory that came with this component.

XMLRPC::Lite
POE::Component::Server::SOAP
POE::Component::Server::HTTP
POE

=head1 AUTHOR & COPYRIGHTS

POE::Component::Server::XMLRPC is Copyright 2002 by 
Mark A. Hershberger.  All rights are reserved.
POE::Component::Server::XMLRPC is free software; you may
redistribute it and/or modify it under the same terms as Perl
itself.

=cut
