#!/usr/bin/perl

my @time;

my $starttime = time;

use strict;
use warnings;
use LWP::UserAgent;
use LWP::ConnCache;
use JSON qw( decode_json );     # From CPAN
use Data::Dumper;               # Perl core module
use DateTime;
use DateTime::Format::ISO8601;
use 5.10.0;
use match::simple qw(match);
use utf8;
use Getopt::Long;
use File::Compare;
use Term::ProgressBar;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);

my $channel_id = $ARGV[0];
my $xmlid = $ARGV[1];

use File::Basename;
chdir dirname(__FILE__);

my $api_key = readApiKey();
my $endpoint = "https://api.honeybee.it/v2";

my %ratings;
my %cattrans;
my %channeltrans;
my $ua = LWP::UserAgent->new();

my $conn_cache = LWP::ConnCache->new();
$conn_cache->total_capacity([10]) ;
$ua->conn_cache($conn_cache);

my $days = 11;
my $maxchannels = 0;
my $onlylisted = 0;
my $nos3 = 0;
my $onlyconfig = 0;
my $showdiff = 0;
my $sluggrep = "";
my $sendmail = 0;
my $force = 0;
my $verbose = 0;
my %updates;

GetOptions ("days=i" => \$days,
            "onlylisted"  => \$onlylisted,
            "onlyconfig"  => \$onlyconfig,
            "showdiff"  => \$showdiff,
            "maxchannels=i"  => \$maxchannels,
            "sluggrep=s"  => \$sluggrep,
            "nos3"  => \$nos3,
            "force"  => \$force,
            "verbose"  => \$verbose,
            "sendmail" => \$sendmail);
	
readCatTranslations();
cleanOldFiles();

say $sluggrep;

my $filters = getChannelFilter();
my $channels = getChannelList($filters);

if ($onlyconfig)
{
    exportChannelConf($channels);
} else {
    loopAllChannels($channels);

    if (!$nos3)
    {
        syncFilesToS3();
    }
}
#printticks();

say Dumper(\%updates);

my $endtime = time;

my $minutes = POSIX::floor(($endtime-$starttime)/60);

say "It took " . $minutes . " minutes and " . ($endtime-$starttime)%60 . " seconds";

exit 0;

# The end

sub exportChannelConf
{
    my($channels) = @_;
    my %exportStruct;
    my @exportArray;

    foreach my $channel (@$channels)
    {
        foreach my $country (@{$channel->{countries}})
        {
            if (!defined $exportStruct{$country})
            {
                $exportStruct{$country} = [];
            }
            push @{$exportStruct{$country}}, $channel;
        }
#        delete $channel->{countries};
        push @exportArray, $channel;
    }

    my $json_encoder = JSON->new->utf8(1);
    $json_encoder->canonical(1); # produce sorted output

    my $json_text = $json_encoder->encode(\@exportArray);

#    say Dumper(\@exportArray) if $verbose;

    my $configName = "appChannelsConf.js";
    my $configZip = "$configName.gz";
    open(my $out, ">", $configName) or die "Can't open $configName: $!";
    print $out $json_text;
    close $out;
    if (-e $configZip)
    {
        system("rm $configZip");
    }
    system("gzip $configName;s3cmd -m application/json --add-header='Content-Encoding: gzip' put $configName.gz s3://easytv.misc --acl-public");
}

sub tick
{
    my $t = times;
    push @time, $t;
}

sub printticks
{
    my $prevt = 0;
    my $i = 0;

    foreach my $t (@time)
    {
        my $diff = +$t-$prevt;
        say "$i: $diff";
        $prevt = $t;
        $i++;
    }
}

sub cleanOldFiles
{
    system("find zipped -mtime +10 -exec rm {} \\;");
    system("find originals -mtime +10 -exec rm {} \\;");
}

sub syncFilesToS3
{
    say "Syncing with S3...";
    system("s3cmd -m application/json --add-header='Content-Encoding: gzip' sync zipped/ s3://tvguideplus --delete-removed --acl-public");
}

sub getChannelFilter
{
    my %filters;
    
    open(my $in, "<", "channels.conf") or die "Can't open channels.conf: $!";
    while (<$in>)
    {
        my $slug = "";
        my $xmltvid = "";
        my $name = "";
                
        if (/^(?!#)(.*) (.*) (.*)/)
        {
            $slug = $1;
            $xmltvid = $2;
            $name = $3;
        } elsif (/^(?!#)(.*) N:(.*)/) {
            $slug = $1;
            $name = $2;
        } elsif (/^(?!#)(.*) (.*)/) {
            $slug = $1;
            $xmltvid = $2;
        } elsif (/^(?!#)\!(.*)/) {
            $slug = $1;
        }

        if ($slug ne "")
        {
            my %channel;
            
            $channel{xmltvid} = $xmltvid;
            $channel{name} = $name;
            
            $filters{$slug} = \%channel;
        }
    }
    close $in;

#    say "Filters = " . Dumper(\%filters) if $verbose;

    return \%filters;
}

sub getChannelList
{
    my($filters) = @_;

#    my $url = "$endpoint/schedule/channels/dk?api_key=$api_key";
    my $url = "$endpoint/schedule/channels?api_key=$api_key";
    say "$url" if $verbose;
    my @channels;
    my $req = new HTTP::Request GET => $url;
    my $res = $ua->request($req);
    if ($res->is_success)
    {
        my $content = $res->content;
        my $json = decode_json( $content );
        
        foreach my $c (@$json)
        {
            my %channel;
#            my $channel_input = $c->{channel};
            my $channel_input = $c;
            my $slug = $channel_input->{slug};
            say "Slug = " . $slug if $verbose;

            my $countries = $channel_input->{countries};
            my $honeybeeName = $channel_input->{name};
            my $honeybeeXmltvid = $channel_input->{xmltvid};

            my $filter = $filters->{$slug};
            if (defined $filter)
            {
                my $filterName = $filter->{name};              
                my $filterXmltvid = $filter->{xmltvid};
                
                if ($filterName eq "" && $filterXmltvid eq "")
                {
                    # do nothing - channel should be skipped
                    say "Skipped $slug" if $verbose;
                } else {
                    # channel is OK - determine the right name + xmltvid
                    $channel{slug} = $slug;
                    $channel{countries} = $countries;
                    if ($filterName ne "")
                    {
                        $channel{name} = $filterName;
                    } else {
                        $channel{name} = $honeybeeName;
                    }
                    if ($filterXmltvid ne "")
                    {
                        if ($filterXmltvid eq $honeybeeXmltvid)
                        {
                            say "$slug $honeybeeXmltvid";
                        }
                        $channel{xmltvid} = $filterXmltvid;
                    } else {
                        $channel{xmltvid} = $honeybeeXmltvid;
                    }
                    say "Channel = " . Dumper(\%channel) if $verbose;
                    push @channels, \%channel;
                }
            } else {
                if (!$onlylisted)
                {
                    $channel{slug} = $slug;
                    $channel{countries} = $countries;
                    $channel{name} = $honeybeeName;
                    $channel{xmltvid} = $honeybeeXmltvid;
                    push @channels, \%channel;
                }
            }
        }
    } else {
        print STDERR $res->status_line, "\n";
    }
    
    #say Dumper(\@channels);
    return \@channels;
}

sub loopAllChannels
{
    my($channels) = @_;
    my $channelcount = 0;

    my $count = scalar @$channels;
    my $progress = Term::ProgressBar->new ({count => $count,
                                            ETA => 'linear'});

    foreach my $c (@$channels)
    {
        if ($sluggrep eq "" || $c->{slug} =~ /$sluggrep/)
        {
            handleChannel($c->{slug}, $c->{xmltvid});
            $channelcount++;
            $progress->update ($channelcount);
#            say "$channelcount out of $count";
            if ($maxchannels && $channelcount >= $maxchannels)
            {
                last;
            }
        }
    }
}

sub handleChannel
{
    my($channel_slug, $xmltvid) = @_;

    my $dt = DateTime->now;

    #say "Fetching $channel_slug ($xmltvid)";

    for (my $i = 1; $i < $days+1; $i++)
    {
        my $date = $dt->ymd;
        my $url = "$endpoint/schedule/listings/$date/$channel_slug.json?api_key=$api_key";
        #print "$url";
        my $req = new HTTP::Request GET => $url;
        my $res = $ua->request($req);
        if ($res->is_success)
        {
            my %output;
            my @pout;

            my $content = $res->content;
            saveContent($content);
            
            if ($force || newContent($xmltvid, $dt->ymd))
            {
                setState($xmltvid, $dt->ymd, "Updated");
                my $json = decode_json( $content );
                my $programs = $json; #->{channels}[0]->{programmes};
                #say " - " . scalar @$programs . " programs found.";
                if (scalar @$programs)
                {
                    foreach my $p (@$programs)
                    {
                        my %oneoutput;
                        my $dt;
                        
                        my %title;
                        $title{''} = $p->{name}->{title};
                        $oneoutput{'title'} = \%title;;
                        my $subtitle = $p->{episode}->{name};
                        if (defined $subtitle && $subtitle ne '')
                        {
                            my %subtitle;
                            $subtitle{''} = $subtitle;
                            $oneoutput{'subTitle'} = \%subtitle;
                        }
                        $oneoutput{'channel'} = $xmltvid;
                        my $desc = $p->{description};
                        if (defined $desc && $desc ne '')
                        {
                            my %description;
                            $description{''} = $desc;
                            $oneoutput{'desc'} = \%description;
                        }
                        $dt = DateTime::Format::ISO8601->parse_datetime($p->{start});
                        $oneoutput{'start'} = $dt->epoch();
                        $dt = DateTime::Format::ISO8601->parse_datetime($p->{stop});
                        $oneoutput{'stop'} = $dt->epoch();
                        
                        # id
                        my $epgio_id = $p->{id};
                        $oneoutput{'id'} = $epgio_id;
        
                        my $category = $p->{content}->{type};
        
                        # poster
                        my $poster = $p->{content}->{$category}->{images}->{fanart}->{original};
                        if (defined $poster && $poster ne '')
                        {
                            $oneoutput{'poster'} = $poster;
                        }
        
                        # imdb_id
                        my $imdb_id = $p->{content}->{$category}->{external_ids}->{imdb};
                        if (defined $imdb_id && $imdb_id ne '')
                        {
                            $oneoutput{'imdb_id'} = $imdb_id;
                            my $rating = imdbRating($p->{content}->{$category}->{ratings});
                            if ($rating > 0)
                            {
                                $oneoutput{'imdb_rating'} = $rating;
                            }
                        }
        
                        # tvdb_id
                        my $tvdb_id = $p->{$category}->{external_ids}->{tvdb};
                        if (defined $tvdb_id && $tvdb_id ne '')
                        {
                            $oneoutput{'tvdb_id'} = $tvdb_id;
                        }
                        
                        # credits (actors/director)
                        if (defined $p->{credits}->{actor})
                        {
                            $oneoutput{'credits'} = $p->{credits};
                        }
        
                        my $finalcat = "";
                        my $genres = $p->{content}->{$category}->{genres};
                        if ($category eq "series")
                        {
                            $oneoutput{'origGenres'} = \@$genres;
                                                    
                            if (checkGenres(["News", "Politics"], \@$genres))
                            {
                                $finalcat = "Nyheder";
                            } elsif (checkGenres(["Kids", "Animation"], \@$genres)) {
                                $finalcat = "Børn & Ungdom";
                            } elsif (checkGenres(["Entertainment", "Lifestyle", "Gameshow"], \@$genres)) {
                                $finalcat = "Underholdning";
                            } elsif (checkGenres(["Reality"], \@$genres)) {
                                $finalcat = "Reality";     
                            } elsif (checkGenres(["Mini-Series", "Sitcom"], \@$genres)) {
                                $finalcat = "Serier";
                            } elsif (checkGenres(["Music", "Musical"], \@$genres)) {
                                $finalcat = "Musik";
                            } elsif (checkGenres(["Cultural", "Cooking"], \@$genres)) {
                                $finalcat = "Kultur";
                            } elsif (checkGenres(["Animals", "Nature", "Home and Garden"], \@$genres)) {
                                $finalcat = "Natur";
                            } elsif (checkGenres(["History", "Biography", "Documentary"], \@$genres)) {
                                $finalcat = "Dokumentar";
                            } elsif (checkGenres(["Comedy", "Drama"], \@$genres)) {
                                $finalcat = "Serier";
                            } else {
                            }
                        } elsif ($category eq "sport") {
                            $finalcat = "Sport";
                        } elsif ($category eq "movie") {
                            if (checkGenres(["Documentary"], \@$genres) && not defined $imdb_id)
                            {
                                $finalcat = "Dokumentar";
                            } else {
                                $finalcat = "Film";
                            }
                        }
                        if ($finalcat eq "")
                        {
    #                        foreach my $key ( sort{$a cmp $b} keys %cattrans )
                            foreach my $key ( keys %cattrans )
                            {
                                if (index($p->{name}->{title}, $key) != -1)
                                {
                                    $finalcat = $cattrans{$key};
                                    last;
                                }
                            }
                        }
                        if ($finalcat eq "")
                        {
                            foreach my $key ( keys %channeltrans )
                            {
                                if (index($channel_slug, $key) != -1)
                                {
                                    $finalcat = $channeltrans{$key};
                                    last;
                                }
                            }
                        }
        #               if ($finalcat eq "")
        #               {
        #                   my $genres = $p->{series}->{genres};
        #                   say "T: " . $p->{name}->{title} . " -- " . join(", ", @$genres);
        #               }
                        my %cathash;
                        my @catarray;
                        push @catarray, $finalcat;
                        $cathash{'en'} = \@catarray;
                        $oneoutput{'category'} = \%cathash;
                        
                        my $episode = $p->{'episode'}->{number};
                        
                        if (defined $episode && $episode ne '')
                        {
                            $episode = $episode-1;
                            my %episodeNum;
                            my $season = $p->{'episode'}->{'season_number'};
                            if (defined $season && $season ne '')
                            {
                                $season = $season-1;
                                $episodeNum{'xmltv_ns'} = $season . "." . $episode . ".";
                            } else {
                                $episodeNum{'xmltv_ns'} = "." . $episode . ".";
                            }
                            $oneoutput{'episodeNum'} = \%episodeNum;;
                        }
        
                        push @pout, \%oneoutput;
        #                     say $oneoutput{'title'} . ": " . $category . " " . Dumper(\$p->{series}->{genres}) . "=>" . $finalcat;
        #                    say Dumper(\%oneoutput);
                    }
                    my %l1struct;
                    my %l2struct;
                    $l2struct{'programme'} = \@pout;
                    $l1struct{'jsontv'} = \%l2struct;
        
                    my $json_encoder = JSON->new->utf8(1);
                    $json_encoder->canonical(1); # produce sorted output
                    my $json_text = $json_encoder->encode(\%l1struct);
    #               say $json_text;
                    my $jsonfilename = $xmltvid . "_" . $dt->ymd . ".js";
                    my $outputfullpath = "zipped/" . $jsonfilename;
                    my $zippedfullpath = "zipped/" . $jsonfilename . ".gz";
                    open(my $out, ">", $outputfullpath) or die "Can't open $outputfullpath: $!";
                    print $out $json_text;
                    close $out;
                    
                    if (-e $zippedfullpath)
                    {
                        system("rm $zippedfullpath");
                    }
                    system("gzip $outputfullpath");
                    
#                    if (! -e $jsonfullpath || compare($outputfullpath, $jsonfullpath))
#                    {
#                        if (! -e $jsonfullpath)
#                        {
#                            say "$jsonfilename did not exist";
#                        } else {
#                            say "$jsonfilename was different";
#                            if ($showdiff)
#                            {
#                                system("ksdiff -w $outputfullpath $jsonfullpath");
#                            }
#                            system("mv -f $jsonfullpath prevjson/");
#                            system("ksdiff $outputfullpath prevjson/$jsonfilename");
#                        }
#                        system("cp -a $outputfullpath json/");
#                    }
#                    if (! -e $zippedfullpath)
#                    {
#                    }
                } else {
                    setState($xmltvid, $dt->ymd, "0 programs");
                }
            } else {
                setState($xmltvid, $dt->ymd, "Same");
            }
        } else {
            setState($xmltvid, $dt->ymd, "Error");
            print STDERR $channel_slug . ": " . $res->status_line, "\n";
            #print "\n";
        }

        $dt->add( days => 1 );
    }
}

sub saveContent
{
    my($content) = @_;
    my $jsonfilename = "downloads/data.js";

    open(my $out, ">", $jsonfilename) or die "Can't open $jsonfilename: $!";
    print $out $content;
    close $out;
}

sub newContent
{
    my($xmltvid, $date) = @_;
    my $downloadFilename = "downloads/data.js";
    my $jsonfilename = "originals/" . $xmltvid . "_" . $date . ".js";
    
    if (! -e $jsonfilename || compare($downloadFilename, $jsonfilename))
    {
        if (! -e $jsonfilename)
        {
            say "$jsonfilename did not exist";
        } else {
            say "$jsonfilename was different";
            if ($showdiff)
            {
                system("ksdiff -w $downloadFilename $jsonfilename");
            }
        }
        system("mv -f $downloadFilename $jsonfilename");
        return 1;
    } else {
        return 0;
    }
}

sub imdbRating
{
    my($results) = @_;
    my $rating = 0;
    foreach my $r (@$results)
    {
        if ($r->{provider} eq "imdb")
        {
                $rating = 0+$r->{rating};
            last;
        }
    }

    return $rating;
}

sub checkGenres
{
    my($searchGenres, $objectGenres) = @_;
    my $found = 0;

    #say "Check " . Dumper(\@$keys) . " in " . Dumper(\@$objects);
    
    foreach my $key (@$searchGenres)
    {
        if (match($key, \@$objectGenres))
        {
            $found = 1;
            last;
        }
    }
    
    return $found;
}

sub readCatTranslations
{
    open(my $cats, "<:encoding(UTF-8)", "category_translation.conf") or die "Can't open category_translation.conf: $!";
    while (<$cats>)
    {
        if (/^(?!#)T \"(.*)\" \"(.*)\"/)
        {
            $cattrans{$1} = $2;
        }
        if (/^(?!#)K \"(.*)\" \"(.*)\"/)
        {
            $channeltrans{$1} = $2;
        }
    }
    close $cats;
}

sub readApiKey
{
    open(my $api_key_file, "<", "apikey.conf") or die "Can't open apikey.conf: $!";
    my $key = <$api_key_file>;
    chomp($key);
    close $api_key_file;
    
    return $key;
}

sub setState
{
    my($xmltvid, $date, $state) = @_;
    
    if (!defined $updates{$xmltvid})
    {
        $updates{$xmltvid} = {};
    }
    
    my $dateHash = $updates{$xmltvid};
    $dateHash->{$date} = $state;
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

