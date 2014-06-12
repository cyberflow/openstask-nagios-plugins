#!/usr/bin/perl -w
#
# check_neutron_l3_ha
#
# This module is free software; you can redistribute it and/or modify it
# under the terms of GNU general public license (gpl) version 3.
# See the LICENSE file for details.

use strict;
use Net::OpenStack::Neutron;
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

sub migration_target_agents {
    my ( $self, $router_id, @available_agents ) = @_;
    my $net_id
        = $self->router_show($router_id)->{external_gateway_info}{network_id};
    my @target_agents_id;
    verbose( "Network ID: " . $net_id, 3 );
    foreach $a (@available_agents) {
        if ( ( $a->{'agent_type'} eq 'L3 agent' )
            && ($a->{configurations}{gateway_external_network_id} eq $net_id )
            && ( $a->{'alive'} ) )
        {
            push( @target_agents_id, $a->{id} );
        }
    }
    verbose( "Agents for migrate: " . Dumper(@target_agents_id), 3 );
    return @target_agents_id;
}

sub move_router {
    my ( $self, $router_id, $src_agent, $dst_agent ) = @_;
    $self->l3_agent_router_remove( $src_agent, $router_id );
    return $self->l3_agent_router_add( $dst_agent, $router_id );
}

sub check_routers {

    sub Ping_it {
        my ( $RequestQ, $ResultQ, $t ) = @_;
        use Net::Ping::External qw(ping);

        #my $pinger = Net::Ping->new('icmp', 1);

        while ( my $target = $RequestQ->dequeue ) {

            #if($pinger->ping($target)) {
            if ( ping( hostname => $target, timeout => 1 ) ) {
                verbose( "Ping $target: OK", 3 );
            }
            else {
                verbose( "No response from $target", 3 );
                $ResultQ->enqueue("$target");
            }

            threads->yield();
        }

        #$pinger->close();
    }

    use threads;
    use Thread::Queue;

    my ($self) = @_;
    my @ports = @{ $self->host_port_list( $options->host ) };
    @ports = grep { $_->{device_owner} eq 'network:router_gateway' } @ports;
    my @ips;
    foreach my $ip (@ports) {
        push( @ips, $ip->{fixed_ips}[0]{ip_address} );
    }
    my $RequestQ = Thread::Queue->new;
    my $ResultQ  = Thread::Queue->new;

    my @kids;
    my @routers_id;

    $RequestQ->enqueue(@ips);
    for ( 0 .. ($#ips) ) {
        $RequestQ->enqueue(undef);
        push @kids, threads->new( \&Ping_it, $RequestQ, $ResultQ, $_ );
    }

    foreach ( threads->list ) {
        $_->join;
    }
    $ResultQ->enqueue(undef);
    while ( my $target = $ResultQ->dequeue ) {
        my @target_port
            = grep { $_->{fixed_ips}[0]{ip_address} eq $target } @ports;
        foreach my $target_id (@target_port) {
            push( @routers_id, $target_id->{device_id} );
        }
    }
    return ( $#ips, @routers_id );
}

sub run {
    $plugin = Nagios::Plugin->new( shortname => 'CHECK_NEUTRON_L3_HA' );

    my $usage = <<'EOT';
check_device_mounted [-H|--host <hostname>] [-A|--authurl <HOST|IP>] [-u|--user] [-T|--tenant] [-p|--passwd] [-P|--port] [-C|--config <path/to/config>]
             [-C|--config <path/to/config>] [-h|--help] [-V|--version] [--usage] [--debug] [--verbose]
EOT

    $options = Nagios::Plugin::Getopt->new(
        usage   => $usage,
        version => $VERSION,
        blurb   => 'Check neutron l3-agent'
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
            = "http://"
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

    my $neutron = Net::OpenStack::Neutron->new(
        auth_url   => $authurl,
        user       => $user,
        tenant     => $tenant,
        password   => $password,
        verify_ssl => ( $options->insecure ) ? 0 : 1,
    );

    my @agents = @{ $neutron->agent_list };
    foreach my $a (@agents) {
        if (   ( $a->{agent_type} eq 'L3 agent' )
            && ( $a->{host} eq $options->host ) )
        {
            verbose(
                "Inspecting L3 agent with id "
                    . $a->{id}
                    . " that have "
                    . $a->{configurations}{routers}
                    . " routers",
                3
            );
            if ( $a->{alive} ) {
                $plugin->nagios_exit( 'OK', "L3 agent is alive" );
            }
            elsif ( $a->{configurations}{routers} > 0 ) {
                my $src_agent_id = $a->{id};
                my ( $checked, @routers_id ) = check_routers($neutron);
                verbose( "Checked " . ( $checked + 1 ) . " routers", 3 );
                verbose(
                    "No response from " . ( $#routers_id + 1 ) . " routers: ",
                    3
                );
                $plugin->set_thresholds(
                    warning  => "$checked:",
                    critical => "~:$checked"
                );
                my $code = $plugin->check_threshold(
                    check => ( $#routers_id + 1 ) );
                if ( $#routers_id = -1 ) {
                    $plugin->nagios_exit( 'WARNING',
                        "L3 agent dead without routers" );
                }
                if ( ( $code == 2 ) && ( $#routers_id > 0 ) ) {
                    my @target_agents_id
                        = migration_target_agents( $neutron, $routers_id[0],
                        @agents );
                    if ( $#target_agents_id == -1 ) {
                        $plugin->nagios_exit( 'CRITICAL',
                            "L3 agent is dead and not suitable candidates for migration found | сколько роутеров?"
                        );
                    }
                    foreach my $router_id (@routers_id) {
                        verbose( "ROUTER ID: " . $router_id, 3 );
                        move_router( $neutron, $router_id, $src_agent_id,
                            $target_agents_id[ rand @target_agents_id ] );
                    }
                    $plugin->nagios_exit( 'WARNING',
                        "L3 agent is dead, routers were migrated | кого смигрили?"
                    );
                }
                $plugin->nagios_exit( $code,
                    "L3 agent is dead, but some routers replied" );
            }
            else {
                $plugin->nagios_exit( 'WARNING',
                    "L3 agent dead without routers" );
            }
        }
    }
    $plugin->nagios_exit( 'CRITICAL',
        "No L3 agent on " . $options->host . " found" );
}
