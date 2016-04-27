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
use Email::MIME;
use Email::Sender::Simple qw(sendmail);

use File::Basename;
chdir dirname(__FILE__);

open(my $in, "<", "cd_channellist.conf") or die "Can't open cd_channellist.conf: $!";

my %channels;
my $log = "";

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
            $log = "$log$channelname ($xmltvid)\n";
            $log = "$log    $_\n" for keys %missing;
        }
    }
}

close $in;

if ($log ne "")
{
    sendemail("Missing channel data!", $log);
}

sub sendemail
{
    my($subject, $body) = @_;
    
    my $message = Email::MIME->create(
                header_str => [
                    From    => 'unpaq.epg@gmail.com',
                    To      => 'jacob@unpaq.com',
                    Subject => $subject,
                              ],
                attributes => {
                    encoding => 'quoted-printable',
                    charset  => 'ISO-8859-1',
                              },
                body_str => $body,
                                      );

    sendmail($message);
}
