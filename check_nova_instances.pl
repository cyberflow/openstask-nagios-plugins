#!/usr/bin/perl -w
#
# check_nova_instances
#
# This module is free software; you can redistribute it and/or modify it
# under the terms of GNU general public license (gpl) version 3.
# See the LICENSE file for details.

use strict;
use Net::OpenStack::Nova;
use feature qw(say);
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
        say $message;
    }

    return;
}

sub run {
    $plugin = Nagios::Plugin->new( shortname => 'CHECK_NOVA_INSTANCES' );

    my $usage = <<'EOT';
check_device_mounted [-H|--host <hostname>] [-A|--authurl <HOST|IP>] [-u|--user] [-T|--tenant] [-p|--passwd] [-P|--port]
             [-C|--config <path/to/config>] [-h|--help] [-V|--version] [--usage] [--debug] [--verbose]
EOT

    $options = Nagios::Plugin::Getopt->new(
        usage   => $usage,
        version => $VERSION,
        blurb   => 'Check nova instances'
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
        spec     => 'insecure',
        help     => 'The server certificate will not be verified',
        required => 0,
    );

    $options->arg(
        spec => 'config|C=s',
        help => qq{'Config file with user and password like plugin.ini file. 
        Example:
          [compute]
          user=username
          tenant=tenantname
          password=supersecretpass
          keystone=hostname.keystone.api'},
        required => 0,
    );

    $options->arg(
        spec     => 'debug',
        help     => 'debugging output',
        required => 0,
    );

    $options->getopts();

    if ( $options->config ) {
        my $Config = Nagios::Plugin::Config->read( $options->config )
            or $plugin->nagios_die(
            "Cannot read config file " . $options->config );
        $user     = $Config->{compute}->{user}[0];
        $tenant   = $Config->{compute}->{tenant}[0];
        $password = $Config->{compute}->{password}[0];
        $authurl
            = "https://"
            . $Config->{compute}->{keystone}[0] . ":"
            . $options->port
            . "/v2.0/";
        verbose( "User: $user;",        3 );
        verbose( "Tenant: $tenant;",    3 );
        verbose( "Passwd: $password;",  3 );
        verbose( "Auth url: $authurl;", 3 );
    }
    elsif ( ( $options->user ) && ( $options->passwd ) ) {
        $user     = $options->user;
        $tenant   = $options->tenant;
        $password = $options->password;
        $authurl  = options->authurl;
        verbose( "User: $user;",        3 );
        verbose( "Tenant: $tenant;",    3 );
        verbose( "Passwd: $password;",  3 );
        verbose( "Auth url: $authurl;", 3 );
    }
    else {
        $plugin->nagios_die(
            "One of arguments needs definition: [-u <user> -T <tenant> -p <passwd> -A <authurl>] | [-C config.ini]"
        );
    }

    my $nova = Net::OpenStack::Nova->new(
        auth_url   => $authurl,
        user       => $user,
        tenant     => $tenant,
        password   => $password,
        verify_ssl => ( $options->insecure ) ? 0 : 1,
    );

    my @instances = @{ $nova->list_all_tenant($options->host) };
    my ( $code, $message);    
    foreach my $i (@instances) {
    	verbose( "Instance: " 
    		. $i->{'OS-EXT-SRV-ATTR:instance_name'}
    		. " | " 
    		. $i->{status}
    		. " | " 
    		. $i->{'OS-EXT-STS:power_state'}, 3);
    	if (($i->{status} eq 'ACTIVE')&&($i->{'OS-EXT-STS:power_state'} != 1)) {
    		$code = 2;
    		$plugin->add_message( $code, 'Instance: ' 
    			. $i->{'OS-EXT-SRV-ATTR:instance_name'} 
    			. ' have wrong statuses on '.$options->host.';'
    			);
    	} elsif ($i->{status} eq 'ERROR') {
    		$code =2;
    		$plugin->add_message( $code, 'Instance: ' 
    			. $i->{'OS-EXT-SRV-ATTR:instance_name'} 
    			. ' have ERROR status on '.$options->host.';'
    			);
    	} else {
    		$code = 0;
    	}

    }
    ( $code, $message ) = $plugin->check_messages();
    $plugin->nagios_exit( $code , $message );
}