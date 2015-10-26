#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON qw( decode_json );     # From CPAN
use Data::Dumper;               # Perl core module
use DateTime;
use DateTime::Format::ISO8601;
use 5.10.0;
use match::simple qw(match);
use utf8;

open(my $api_key_file, "<", "apikey.conf") or die "Can't open apikey.conf: $!";
my $api_key = <$api_key_file>;
chomp($api_key);
close $api_key_file;
    
my $endpoint = "https://api.epg.io/v1";
my $ua = LWP::UserAgent->new();

my $url = "$endpoint/schedule/channels.xml?api_key=$api_key";

system("wget $url -O channels.xml");


