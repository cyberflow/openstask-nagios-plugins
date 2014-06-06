#!/usr/bin/perl -w
#
# check_neutron_agent
#
# This module is free software; you can redistribute it and/or modify it
# under the terms of GNU general public license (gpl) version 3.
# See the LICENSE file for details.

use strict;
use Net::OpenStack::Neutron;
use Data::Dumper;

our $VERSION = '0.1';

use Nagios::Plugin::Getopt;
use Nagios::Plugin::Threshold;
use Nagios::Plugin::Config;
use Nagios::Plugin;

use vars qw(
  $plugin
  $options
  $user
  $tenant
  $password
  $authurl
);

if ( !caller ) {
    run();
}

# sub _cache {
#     my $self = shift;
#     my $cache = Cache::File->new( cache_root => $options->cache,
# 				  default_expires => '86400 sec');
#     return $cache;
# }

sub verbose {
    # arguments
    my $message = shift;
    my $level   = shift;

    if ( !defined $message ) {
        $plugin->nagios_exit( UNKNOWN,
            q{Internal error: not enough parameters for 'verbose'} );
    }

    if ( !defined $level ) {
        $level = 0;
    }

    if ( $options->debug() ) {
        print '[DEBUG] ';
    }

    if ( $level < $options->verbose() || $options->debug() ) {
        print $message;
    }

    return;
}

sub run {
     $plugin = Nagios::Plugin->new( shortname => 'CHECK_NEUTRON_AGENT' );

     my $usage = <<'EOT';
check_device_mounted [-H|--host <hostname>] [-A|--authurl <HOST|IP>] [-u|--user] [-T|--tenant] [-p|--passwd] [-P|--port] [-a|--agent_type] [-C|--config <path/to/config>]
             [-C|--config <path/to/config>] [-h|--help] [-V|--version] [--usage] [--debug] [--verbose]
EOT
        
     $options = Nagios::Plugin::Getopt->new(
        usage   => $usage,
        version => $VERSION,
        blurb   => 'Check neutron agent'
     );

     $options->arg(
        spec     => 'host|H=s',
        help     => 'hostname',
        required => 1,
     );
	
     $options->arg(
        spec     => 'authurl|A=s',
        help     => 'Auth URL keystone server',
    	default  => 'localhost',
        required => 0,
     );

     $options->arg(
        spec     => 'port|P=s',
        help     => 'Auth URL keystone port',
	    default  => '5000',
        required => 0,
     );

     $options->arg(
        spec     => 'user|u=s',
        help     => 'user name',
        required => 0,
     );

     $options->arg(
        spec     => 'tenant|T=s',
        help     => 'tenant name',
        required => 0,
     );

     $options->arg(
        spec     => 'password|p=s',
        help     => 'user password',
        required => 0,
     );

     $options->arg(
        spec     => 'agent_type|a=s',
        help     => 'type of agent ("DHCP agent", "L3 agent")',
        default  => 'DHCP agent',
        required => 0,
     );

     $options->arg(
        spec     => 'insecure',
        help     => 'The server certificate will not be verified',
        required => 0,
     );

     $options->arg(
        spec     => 'config|C=s',
        help     => qq{'Config file with user and password like plugin.ini file. 
        Example:
          [compute]
          user=username
          tenant=tenantname
          password=supersecretpass
          keystone=hostname.keystone.api'},
        required => 0,
     );

     # $options->arg(
     #    spec     => 'cache=s',
     #    help     => 'Cache dir (default: /tmp/check_ganglia)',
     #    default  => '/run/shm/keystone_auth',
     #    required => 0,
     # );

     $options->arg(
        spec     => 'debug',
        help     => 'debugging output',
        required => 0,
     );
     
     $options->getopts();

     if ($options->config) {
		 my $Config = Nagios::Plugin::Config->read( $options->config )
		     or $plugin->nagios_die("Cannot read config file " . $options->config);
		 $user     = $Config->{compute}->{user}[0];
		 $tenant   = $Config->{compute}->{tenant}[0];
		 $password = $Config->{compute}->{password}[0];
		 $authurl  = "https://".$Config->{compute}->{keystone}[0].":".$options->port."/v2.0/";
		 verbose ("User: $user;\n", 3); 
	         verbose ("Tenant: $tenant;\n", 3); 
	         verbose ("Passwd: $password;\n", 3); 
		 verbose ("Auth url: $authurl\n", 3);
     } elsif (($options->user) && ($options->passwd)) {
	 	 $user     = $options->user;
	 	 $tenant   = $options->tenant;
		 $password = $options->password;
		 $authurl  = options->authurl;
		 verbose ("User: $user;\n", 3); 
	         verbose ("Tenant: $tenant;\n", 3); 
	         verbose ("Passwd: $password;\n", 3); 
		 verbose ("Auth url: $authurl\n", 3);
	 } else {
	 	 $plugin->nagios_die("One of arguments need definition: [-u <user> -T <tenant> -p <passwd> -A <authurl>] | [-C config.ini]");
     }

     my $neutron = Net::OpenStack::Neutron->new(
        auth_url     => $authurl,
        user         => $user,
        tenant       => $tenant,
        password     => $password,
        verify_ssl   => ($options->insecure) ? 0 : 1,
    );

     my @agents = @{ $neutron->agent_list };
     foreach my $a ( @agents ) {
		 if (($a->{'agent_type'} eq $options->agent_type) && ($a->{'host'} eq $options->host)) {
            verbose (Dumper($a)."\n", 3);
		 	if ($a->{'alive'}) {
				$plugin->nagios_exit( 'OK', $options->agent_type." alive" );
		 	} else {
		 		$plugin->nagios_exit( 'CRITICAL', $options->agent_type." are not be alive." );
		 	}
		 }
     }

	 $plugin->nagios_exit( 'CRITICAL', $options->agent_type." were not obtained." );     
}
