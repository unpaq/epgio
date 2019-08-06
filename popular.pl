#!/usr/bin/perl

use strict;
use warnings;
use JSON;
use 5.10.0;
use Data::Dumper;
use LWP::UserAgent;
use DateTime;

use File::Basename;
chdir dirname(__FILE__);

my $ua = LWP::UserAgent->new();

my %programs;
my %programs2;

open(my $api_token_file, "<", "flurryapitoken.conf") or die "Can't open flurryapitoken.conf: $!";
my $api_token = <$api_token_file>;
chomp($api_token);
close $api_token_file;

my $dt = DateTime->now;
my $enddate = $dt->ymd;
$dt = $dt->subtract(days => 5);
my $startdate = $dt->ymd;
#my $url = "http://api.flurry.com/eventMetrics/Event?apiAccessCode=$api_access_code&apiKey=$api_key&startDate=$startdate&endDate=$enddate&eventName=Favorite%20added%20new";
my $url = "https://api-metrics.flurry.com/public/v1/data/eventParams/day/event;show=all/event/paramName/paramValue?metrics=count&filters=app|name-in[Easy TV 2],event|name-in[Favorite added new]&dateTime=$startdate/$enddate";
say "URL = $url";
my $req = new HTTP::Request GET => $url;
$req->header( "Authorization" => "Bearer " .  $api_token);
my $res = $ua->request($req);

if ($res->is_success)
{
    my $content = $res->content;
    my $json = decode_json( $content );
#    say Dumper($json);
    my $eventparams =  $json->{"rows"};
#    my $events =  $json->{parameters}->{key}->{value};

    foreach my $eventparname (@$eventparams)
    {
        my $eventparam = $eventparname->{'paramName|name'};
        if ($eventparam eq "Channel: Title")
        {
            my $name = $eventparname->{'paramValue|name'};
            my $count = $eventparname->{'count'};

            $programs{$name} += $count;
        }
    }
}

#say Dumper(%programs);

my $index=0;
foreach my $title (sort { $programs{$b} <=> $programs{$a} } keys %programs) {
    if ($title ne "com.flurry.OTHER")
    {
        say $programs{$title} . ": " . $title;
    }
    $programs2{$title} = $programs{$title};    
    $index++;
    if ($index>50)
    {
      last;
    }
}

#while ( (my $k, my $v) = each %programs2 ) { print "$k => $v\n"; }

my $json_text = JSON->new->utf8(1)->encode(\%programs2);

#say $json_text;

open(my $out, ">", "popular.json") or die "Can't open popular.json: $!";
print $out $json_text;
close $out;

system("rm popular.json.gz");
system("gzip popular.json");
system("cp popular.json.gz zipped/");
system("s3cmd put popular.json.gz s3://tvguideplus --acl-public -m application/json --add-header='Content-Encoding: gzip'");
system("s3cmd put popular.json.gz s3://easytv.misc --acl-public -m application/json --add-header='Content-Encoding: gzip'");

