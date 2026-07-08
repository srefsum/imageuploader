#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;


sub getHostIPAdress {
 
    my $ip_pattern = qr /inet (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\//;
    my $host_ip_address;
    my $ip_string = `ip -4 -o addr show eth0`;
    print $ip_string . "\n";
    if ($ip_string =~ /$ip_pattern/) {
        $host_ip_address=$1;
    }

    return $host_ip_address;
}

print getHostIPAdress();



