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

open(my $in, "<", "cd_channellist.conf") or die "Can't open cd_channellist.conf: $!";

my %channels;

my $filelist = `s3cmd --config /home/jacob/.s3cfg ls s3://tvguideplus`;

while (<$in>)
{
    if (/^(?!#)(.*?) (.*)/)
    {
        my $channelname;
        my $xmltvid;
        my %missing;

        $channelname = $2;
        $xmltvid = $1;
        
        my $dt = DateTime->now();
        for (my $i = 1; $i < 10; $i++)
        {
            my $date = $dt->ymd;
            my $string = $xmltvid . "_" . $date;
            $missing{$string} = 1;
            $dt->add( days => 1 );
        }
        
        for (split /^/, $filelist)
        {
            if (/^(.*)    (.*) s3(.*)tvguideplus.$xmltvid.(.*).js.gz/)
            {
                if ($2 > 200)
                {
                    my $string = $xmltvid . "_" . $4;
                    delete $missing{$string};
                }
            }
        }

        if (scalar %missing)
        {
            say "$channelname ($xmltvid)";        
            say "    $_" for keys %missing;
        }
    }
}

close $in;



