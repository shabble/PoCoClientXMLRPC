package POE::Component::Client::XMLRPC;

use strict;
use warnings;

use Carp qw(croak cluck);
use vars qw($VERSION);
$VERSION = '0.02';

use Data::Dumper;

use MooseX::POE; #with qw/MooseX::POE::Aliased/;
use Moose::Util::TypeConstraints;

use POE::Component::Client::HTTP;

use XMLRPC::Lite;
use HTTP::Request;
use HTTP::Status qw/:constants/;

use URI;

has 'kernel' =>
  (
   is      => 'ro',
   isa     => 'POE::Kernel',
   default => sub { $POE::Kernel::poe_kernel },
   handles => { post => 'post' },
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
   isa      => 'Str',
   required => 1,
   lazy     => 1,
   builder  => '_create_http_transport',
  );

has 'debug' =>
  (
   is       => 'rw',
   isa      => 'Bool',
   required => 1,
   lazy     => 1,
   default  => sub { 0 },
  );

subtype 'HttpUri'
  => as 'Maybe[URI::http]';

coerce 'HttpUri'
  => from 'Str'
  => via { URI->new($_) };

has 'uri' =>
  (
   is       => 'rw',
   isa      => 'HttpUri',
   coerce   => 1,
   required => 1,
   lazy     => 1,
   #TODO: move this into a proper named sub.
   trigger  => sub {
       my ($s, $n, $o) = @_;
       unless (length $n->path_query) {
           $n->path('/RPC2');
       }
       return $n;
   },
   default  => sub { undef },
  );

has 'timeout' =>
  (
   is       => 'ro',
   isa      => 'Num',
   required => 1,
   default  => sub { 10 },
  );

sub START {
    my ($self) = @_;
    $self->kernel->alias_set($self->name);
    # ensure the transport gets constructed, since it's lazy-loading.
    $self->http_transport;
    print STDERR "Starting up client: " . $self->name . "\n" if $self->debug;
    print STDERR "URI set to: " . $self->uri . "\n" if $self->debug;
}

sub STOP {
    my ($self) = @_;
    print STDERR $self->name . " is stopping\n" if $self->debug;
}

sub _create_http_transport {
    my $self = shift;
    print STDERR "creating transport\n" if $self->debug;
    my $alias = 'xmlrpc_http_transport'; # this should probably make sure
    # the alias is unique? or just store a session reference?
    #TODO: steal the approach out of Server::HTTP (regex and session id)
    #TODO: make these parameters configurable.
    POE::Component::Client::HTTP->spawn
        (
         Alias   => $alias,
         Timeout => $self->timeout,
        );
    return $alias;
}

sub _build_request {
    my ($self, $method, $url, @args) = @_;
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'text/xml');

    my $uri = $req->uri;
    # yurk. Add a /RPC2 default if there's no path or query string set.
    # Python XMLRPCLIB seems to behave like this, although there's nothing
    # in the spec.
    unless (length $uri->path_query) {
        $uri->path('/RPC2');
    }

    print STDERR "URI Path: ",$uri->path_query, $/ if $self->debug;

    push @args, () unless @args;
    #TODO: maybe have some way of passing specifically typed args?

    #push @args, XMLRPC::Data->name('name')->value('bob')->type('base64');
    #push @args, XMLRPC::Data->name('id')->value(10)->type('int');

    print STDERR "Args set to: ", Dumper(\@args), $/ if $self->debug;
    my $data = eval {
        XMLRPC::Serializer->envelope('method', $method, @args);
    };
    if ($@) {
        cluck "xmlrpc serialising failed: $@";
    }
    $req->header('Content-Length' => length $data);
#    $req->header(Connection => 'close');
    $req->content($data);

    return $req;
}

sub DEFAULT {
    die "Default handler called";
}

event 'xmlrpc_call' => sub {

    my ($self, $sender, $response_to, $fault_to, $method, $arg_ref)
      = @_[OBJECT, SENDER, ARG0 .. ARG3];
    $sender = $sender->ID();
    print STDERR "call:$method from:$sender, r:$response_to, f:$fault_to\n"
      if $self->debug;
    # build a request
    my $req = $self->_build_request($method, $self->uri, @$arg_ref);

    # throw it over to the http client
    $self->kernel->post($self->http_transport
                        => request
                        => got_xmlrpc_response
                        => $req
                        => [$sender, $response_to, $fault_to]
                       );
};

event 'got_xmlrpc_response' => sub {
    my ($self, $req, $resp) = @_[OBJECT, ARG0, ARG1];
    # check response code
    my ($response) = $resp->[0];
    my $tag = $req->[1];
    print STDERR "Response ", $response->code, $/ if $self->debug;
    my $response_to = $poe_kernel->ID_id_to_session($tag->[0]);

    my $headers = $response->headers;
    if ($response->is_success && $headers->content_is_xml) {
        # deserialise response (may fail if we get malformed xml)
        my $data = eval {
            XMLRPC::Deserializer->deserialize($response->content);
        };
        if ($@) {
            print STDERR "Error in deserialization: $@\n" if $self->debug;
            $self->kernel->post
              ($response_to, $tag->[2],
               {faultCode => 500,
                faultString
                => "Client::XMLRPC failed to deserialize the response"}
              );
        }
        if ($data->fault) {
            $self->kernel->post($response_to, $tag->[2], $data->fault);
        } else {
            my $return_value = @{ $data->valueof('params') // [] }[0];
            #print Dumper($return_value);
            my $ret = $self->kernel->post($response_to, $tag->[1], $return_value);
            if (!$ret) {
                cluck "Error posting response: ", $!, $/;
            }
        }
    } else {
        #TODO: check if it was a failure, OR the content-type and send different codes.
        if ($response->code == HTTP_REQUEST_TIMEOUT) {
            $self->kernel->post($response_to, $tag->[2],
                                {faultCode => 408,
                                 faultString
                                 => "Client::XMLRPC timed out waiting for response"});
        } elsif (0) {
        } else {
            $self->kernel->post($response_to, $tag->[2],
                                {faultCode => 500,
                                 faultString
                                 => "Client::XMLRPC failed to parse response"});
        }
    }
};

event 'shutdown' => sub {
    my ($self) = @_;

    print STDERR "Shutting down ", __PACKAGE__, "\n" if $self->debug;

    $self->kernel->post($self->http_transport => 'shutdown');

    $self->kernel->alias_remove($self->name);
};

no MooseX::POE;
no Moose::Util::TypeConstraints;

__PACKAGE__->meta->make_immutable();

__END__;

=head1 NAME

POE::Component::Client::XMLRPC - Non-blocking XMLRPC client for POE

=head1 VERSION

Version 0.02

=head1 SYNOPSIS

    my $client = POE::Component::Client::XMLRPC->new(uri => 'http://example.com/RPC2');
    $poe_kernel->post

=head1 ATTRIBUTES

=head2 name

Returns the alias used by L<POE::Kernel> to address messages sent to the session.
This attribute is read-only, and must be passed to the C<new> constructor.

=head2 debug

Controls debugging output of the Component. Setting to C<1> enables debug output.
Can be set at construction or during operation.

=head2 uri

Sets the URI of the XMLRPC service to be called.  If the URI specifies no path or
query string, the actual URI used will have C</RPC2> appended.

=head1 METHODS

=head2 new

Creates a new instance of the XMLRPC Client.  The C<name> field is mandatory. All
other attributes listed above are optional.

=head1 EVENTS

=head2 xmlrpc_call

Takes the following arguments:

=over

=item B<Response State>

The name of the state which will receive a response if
the XMLRPC call is successful.  The response will be posted to the
C<xmlrpc_call> C<$_[CALLER]> session, and will be passed the result of the
XMLRPC call in C<$_[ARG0]>.


=item B<Fault State>

The name of the state which will receive a response if the
XMLRPC call returns a fault code.  The response will be posted to the
C<xmlrpc_call> C<$_[CALLER]> session, and will be passed a hashref of the
fault info  in C<$_[ARG0]>.  This hashref will contain exactly two keys, C<faultCode>
specifying a numeric code, and C<faultString> containing a string describing the
reason for the fault.

=item B<RPC Function Name>

The name of the function to be called.

=item B<RPC Function Arguments>

The arguments which should be passed to the RPC
function.  This should be an array-reference comprising the arguments.

=back

=head3 Example

    $poe_kernel->post(xmlrpc_client
                   => xmlrpc_call
                   => my_response
                   => my_fault
                   => some_function
                   => [1, 2, 3, 4]);

=head2 shutdown

Cleans up the L<POE::Component::Client::HTTP> transport component, and then
removes the alias for this component, allowing it to be garbage collected.

Takes no arguments.

=head1 DEPENDENCIES

=over

=item * L<MooseX::POE>

=item * L<POE::Component::Client::HTTP>

=back

=head1 AUTHOR & COPYRIGHTS

Author: Tom Feist

POE::Component::Client::XMLRPC is based heavily on
L<POE::Component::Server::XMLRPC> which is Copyright 2002 by
Mark A. Hershberger.  All rights are reserved.

POE::Component::Client::XMLRPC is free software; you may
redistribute it and/or modify it under the same terms as Perl
itself.

=cut
