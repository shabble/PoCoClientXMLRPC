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
#plan tests => 1;


done_testing;

