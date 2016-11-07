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

my $channelSlug = $ARGV[0];

open(my $api_key_file, "<", "../apikey.conf") or die "Can't open apikey.conf: $!";
my $api_key = <$api_key_file>;
chomp($api_key);

my $endpoint = "https://api.honeybee.it/v2";
my $ua = LWP::UserAgent->new();

            my $url = "$endpoint/schedule/channels.json?api_key=$api_key";
            say "URL = $url";
            my $req = new HTTP::Request GET => $url;
            my $res = $ua->request($req);
            if ($res->is_success)
            {
                my $content = $res->content;
                my $json = decode_json( $content );
                my $channels = $json;
                my $count = 0;
                foreach my $c (@$channels)
                {
                    $count = $count + 1;
                    my $slug = $c->{"slug"};
                    if ($channelSlug eq "" || $channelSlug eq $slug)
                    {
                        my $xmltvid = $c->{"xmltvid"};
                        my $svglogo = $c->{"logos"}->{"svg"};
                        {
                            say $c->{"name"} . " " . $svglogo;
                            system("rm logo.svg");
                            say "Downloading " . $c->{"name"};
                            system("wget $svglogo -O logo.svg");
                            system("rm png/$xmltvid.png");
                            say "Converting to PNG";
                            system("inkscape -z -e png/$xmltvid.png -w 1000 --export-background-opacity=0.0 logo.svg");
                            say "Scaling";
                            system("mogrify -monitor -trim -resize 500x500 png/$xmltvid.png");
                        }
                    }
                }
                say "Squash PNGs";
                system("pngquant --quality=0-90 -v -f --ext .png png/*.png");
                say "Sync with S3";
                system("s3cmd sync png/ s3://easytv.logos --delete-removed --acl-public");
            } else {
                print STDERR $res->status_line, "\n";
            }

