use Module::Build;
my $build = Module::Build->new(
  module_name => POE::Component::Server::XMLRPC,
  license  => perl,
  create_makefile_pl => passthrough,
  requires => {
    perl                         => '5.10.0',
    Test::Exception              => '0.27',
    POE                          => '1.006',
    Moose                        => '0.92',
    MooseX::POE                  => '0.205',
    POE::Component::Client::HTTP => '0.88',
    POE::Component::Server::HTTP => '0.09',
    SOAP::Lite                   => '0.710',
    Test::Simple                 => '0.94',
  },
);
$build->create_build_script;
