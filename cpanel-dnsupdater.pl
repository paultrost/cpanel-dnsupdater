#!/usr/bin/env perl

use strict;
use warnings;

use LWP::UserAgent;
use MIME::Base64;
use XML::Simple;
use LWP::Simple;
use Socket;
use Getopt::Long;
use Pod::Usage;
use Sys::Hostname;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use Net::SMTPS;
use Net::Ping::External qw(ping);
use Data::Validate::IP;

#-------------------------------------------------------------------------------
#  Parse options
#-------------------------------------------------------------------------------

#pod2usage(1) if !@ARGV;

my $error;
my $homedir     = ( getpwuid($>) )[7];
my $config_file = "$homedir/.cpaneldyndns";
my %opts        = ( 'helo' => hostname(), );

GetOptions(
    \%opts,
    'help|?',
    'domain=s' => \$opts{'domain'},
    'host=s'   => \$opts{'host'},
    'ip=s'     => \$opts{'ip'},

    # cPanel connection parameters
    'cpanel_user=s'   => \$opts{'cpanel_user'},
    'cpanel_pass=s'   => \$opts{'cpanel_pass'},
    'cpanel_domain=s' => \$opts{'cpanel_domain'},

    # SMTP parameters to send change email
    'helo=s'            => \$opts{'helo'},
    'email_auth_user=s' => \$opts{'email_auth_user'},
    'email_auth_pass=s' => \$opts{'email_auth_pass'},
    'email_addr=s'      => \$opts{'email_addr'},
    'outbound_server=s' => \$opts{'outbound_server'},

    # IP for outbound connection check
    'check_host=s' => \$opts{'check_host'},

    # Location of the configuration file
    'config_file=s' => \$config_file
) or die "Invalid options passed to $0\n";

if ( -e $config_file ) {
    open( my $cf_fh, "<", $config_file )
      or warn "could not open $config_file";
  LINE:
    while ( my $cf_line = <$cf_fh> ) {    # read each line
        chomp $cf_line;
        next LINE if $cf_line eq '' || $cf_line =~ /^#/;
        my ( $key, $value ) = split( /=/, $cf_line );
        $opts{$key} = $value;
    }
    close($cf_fh);
}

pod2usage(1) if $opts{'help'};

die "Required parameters not specified or no configuration file found. Run '$0 --help' for instructions.\n"
  unless $opts{'domain'}
  and $opts{'host'}
  and $opts{'cpanel_user'}
  and $opts{'cpanel_pass'}
  and $opts{'cpanel_domain'}
  and $opts{'check_host'};

# Set default $email_addr
$opts{'$email_addr'} ||= $opts{'email_auth_user'};

# Use email for output instead of STDOUT if email parameters specified
my $send_email = ( $opts{'email_addr'} ) ? 1 : 0;

#-------------------------------------------------------------------------------
#  Validate user input
#-------------------------------------------------------------------------------

my $validator = Data::Validate::IP->new;
if ( $opts{'ip'} && !$validator->is_ipv4( $opts{'ip'} ) ) {
    die "Specified IP address '$opts{'ip'}' doesn't look like an IPv4 address.\n";
}

#-------------------------------------------------------------------------------
#  Set user account parameters
#-------------------------------------------------------------------------------
my $auth = 'Basic ' . MIME::Base64::encode( $opts{'cpanel_user'} . ':' . $opts{'cpanel_pass'} );

#-------------------------------------------------------------------------------
#  Disable SSL validation
#-------------------------------------------------------------------------------
my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0 } );

#-------------------------------------------------------------------------------
#  Main code body
#-------------------------------------------------------------------------------

# Set update IP to detected remote IP address if IP not specified on cmd line
my $external_ip = $opts{'ip'} || get_external_ip();

# Get current host IP address and see if it matches the given IP
my ( $current_ip_line, $current_ip ) = get_zone_data( $opts{'domain'}, $opts{'host'} );
if ( $current_ip eq $external_ip ) {
    #Detected remote IP $external_ip matches current IP $current_ip; no IP update needed.
    exit(0);
}

#print "Trying to update $opts{'host'} IP to $external_ip ...\n";
my $result = set_host_ip( $opts{'domain'}, $current_ip_line, $external_ip );
if ( $result eq 'succeeded' ) {
    output("Update successful! Changed $current_ip to $external_ip\n");
    exit(0);
}
else {
    $error = 1;
    output("Update not successful, $result\n");
    exit(1);
}

print "Reached end of script, something bad happened\n";
exit(255); 

sub output {
    my ($status_msg) = @_;
    die "No status message supplied\n" if !$status_msg;
    return ($send_email) ? send_email($status_msg) : print $status_msg;
}

sub send_email {
    my ($body_text) = @_;
    my $success_subject = "Updated IP address for " . "$opts{'host'}.$opts{'domain'}";
    my $subject = $error ? "Issue detected when running" : $success_subject;

    # If the SMTP transaction is failing, add 'Debug => 1,' to the method below
    # which will output the full details of the SMTP connection
    my $smtp = Net::SMTPS->new(
        $opts{'outbound_server'},
        Hello           => $opts{'helo'},
        Port            => 587,
        Timeout         => 20,
        doSSL           => 'starttls',
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
    ) or die "Could not connect to $opts{'outbound_server'}\n$@\n";

    $smtp->auth( $opts{'email_auth_user'}, $opts{'email_auth_pass'} )
      or die "Couldn't send email: ", $smtp->message();
    $smtp->mail( $opts{'email_auth_user'} );
    $smtp->to( $opts{'email_addr'} )
      or die "Couldn't send email: ", $smtp->message();
    $smtp->data();
    $smtp->datasend("From: $opts{'email_auth_user'}\n");
    $smtp->datasend("To: $opts{'email_addr'}\n");
    $smtp->datasend("Subject: $0 - $subject\n");
    $smtp->datasend( 'Date: ' . localtime() . "\n" );
    $smtp->datasend("\n");
    $smtp->datasend($body_text);
    $smtp->dataend();
    $smtp->quit();
    return 1;
}

sub get_zone_data {
    my ( $domain, $hostname ) = @_;
    $hostname .= ".$domain.";

    my $xml = XML::Simple->new;
    my $request =
      HTTP::Request->new( GET =>
"https://$opts{'cpanel_domain'}:2083/xml-api/cpanel?cpanel_xmlapi_module=ZoneEdit&cpanel_xmlapi_func=fetchzone&domain=$domain"
      );
    $request->header( Authorization => $auth );
    my $response = $ua->request($request);
    my $zone;
    $zone = eval { $xml->XMLin( $response->content ) };

    if ( !defined $zone ) {
        $error = 1;
        output(
"Couldn't connect to '$opts{'cpanel_domain'}' to fetch zone contents for $domain\nPlease ensure 'cpanel_domain', 'cpanel_user', and 'cpanel_pass' are set correctly.\n"
        );
        output( $response->content );
        exit(1);
    }

    # Assuming we find the zone, iterate over it and find the $hostname record
    my ( $record_number, $address, $found_hostname );
    if ( $zone->{'data'}->{'status'} eq '1' ) {
        my $count = @{ $zone->{'data'}->{'record'} };
        my $item  = 0;
        while ( $item <= $count ) {
            my $name = $zone->{'data'}->{'record'}[$item]->{'name'};
            my $type = $zone->{'data'}->{'record'}[$item]->{'type'};
            if ( ( defined($name) && $name eq $hostname ) && ( $type eq 'A' ) )
            {
                $record_number = $zone->{'data'}->{'record'}[$item]->{'Line'};
                $address = $zone->{'data'}->{'record'}[$item]->{'address'};
                $found_hostname = 1;
            }
            $item++;
        }
    }
    else {
        output("Couldn't fetch zone for $domain.\n$zone->{'event'}->{'data'}->{'statusmsg;'}\n");
        exit(1);
    }

    if ( !$found_hostname ) {
        output("No A record present for $hostname, please verify it exists in the cPanel zonefile!\n");
        exit(1);
    }
    return ( $record_number, $address );
}

sub set_host_ip {
    my ( $domain, $line_number, $newip ) = @_;
    my $xml = XML::Simple->new;
    my $request =
      HTTP::Request->new( GET =>
"https://$opts{'cpanel_domain'}:2083/xml-api/cpanel?cpanel_xmlapi_module=ZoneEdit&cpanel_xmlapi_func=edit_zone_record&domain=$domain&line=$line_number&address=$newip"
      );
    $request->header( Authorization => $auth );
    my $response   = $ua->request($request);
    my $reply      = $xml->XMLin( $response->content );
    my $set_status = $reply->{'data'}->{'status'};
    return ( $set_status == 1 ) ? 'succeeded' : $reply->{'data'}->{'statusmsg'};
}

sub get_external_ip {

    #check for connectivity
    #no need to run any further if connection out is dead
    my $alive = ping( 'host' => $opts{'check_host'} );
    exit(1) if !$alive;

    #grab detetected IP address
    my $url = 'http://go.cpanel.net/myip';
    my $ip;
    if ( !defined $opts{'ip'} ) {
        $ip = get($url);
        if ( !$validator->is_ipv4($ip) ) {
            die "'$url' didn't return an IP address:\n" . "$ip\n";
        }
        chomp $ip;
        if ( !$ip ) {
            $error = 1;
            output(
"Couldn't connect to $url, it may be unresponsive or not work amymore.\n"
            );
            exit(1);
        }
    }
    return $ip;
}

=pod

=head1 NAME

 cpanel-dnsupdater.pl

=cut

=head1 VERSION

 0.8.7

=cut

=head1 USAGE

 cpanel-dnsupdater.pl [options]

 Example:
 cpanel-dnsupdater.pl --host home --domain domain.tld --cpanel_user cptest --cpanel_pass 12345 --cpanel_domain cptest.tld --check_host 8.8.8.8

=cut

=head1 DESCRIPTION

 This script is useful for updating the IP address of an A record on a cPanel hosted domain with either a supplied IP, or a detected IP. This allows you to use your own cPanel domain for dynamic DNS instead of having to use a third party DNS service. 
 
 If your specify email address parameters, then script output is emailed to you, otherwise all output is printed to STDOUT.

=cut

=head1 ARGUMENTS

=head2  Required

  --host          Host name to update in the domain's zonefile. eg. 'www'
  --domain        Name of the domain to update
  --cpanel_user   cPanel account login name
  --cpanel_pass   cPanel account password
  --cpanel_domain cPanel account domain name
  --check_host    IP address of host to check for connectivity. eg. 8.8.8.8 or your DNS resolver

=head2  Optional

  --ip              IP address to update the A record with. This defaults to the detected external IP.
  --email_auth_user Email address for SMTP Auth
  --email_auth_pass Password for SMTP Auth (use \ to escape characters)
  --email_addr      Email address to send successful/error report to (defaults to email_auth_user)
  --outbound_server Server to send mail through
  --helo            Change the HELO that is sent to the outbound server, this setting defaults to the current hostname
  --config_file     Specify the location of a configuration file (defaults to ~/.cpaneldyndns)

=head2 Using a Config File (~/.cpaneldyndns)

    Instead of passing options on the command line, a configuration file can be used.
    Any options specified on the command line will be overriden by the configuration file options.
    The file takes the format of 'option=value', eg:
    host=home
    domain=mydomain.com
    
    The default location of the file is in the home directory of the current user and the default filename is '.cpaneldyndns'

=cut

=head1 EXIT STATUS

 Exits with 1 if there was any issue updating the record, 255 if the end of script was reached in error, and 0 if IP was either changed, or the detected IP matches the given IP.

=head1 AUTHOR

 Paul Trost <ptrost@cpanel.org>
 Original code by Stefan Gofferje - http://stefan.gofferje.net/

=cut

=head1 LICENSE AND COPYRIGHT

 Copyright 2012, 2013, 2014, 2015.
 This script is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License v2, or at your option any later version.
 <http://gnu.org/licenses/gpl.html>
