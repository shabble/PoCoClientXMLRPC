

use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME         => 'POE::Component::Server::XMLRPC',
    VERSION_FROM => 'lib/POE/Component/Server/XMLRPC.pm', # finds \$VERSION
    AUTHOR       => 'Tom Feist (shabble@cowu.be)',
    ABSTRACT     => 'Module abstract (<= 44 characters) goes here',
    PREREQ_PM    => {
                     'Test::Simple' => 0.44,
                    },
);
