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
        syncLogos();
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
    my @exportArray;

    foreach my $channel (@$channels)
    {
        if ($channel->{name} =~ /(.*\S) ?\((DK|DE|SE|NO|FI|PL|NL|CH|AT)\) *\(?(English)?/)
        {
            if (! defined $3 || $3 eq "")
            {
                say "$channel->{name} -> $1" if $verbose;
                $channel->{name} = $1;
            } else {
                say "$channel->{name} -> $1 $3" if $verbose;
                $channel->{name} = "$1 $3";
            }
            if ($2 ne "")
            {
                $channel->{lang} = $2;
            }
        } else {
            say $channel->{name} if $verbose;
        }
        delete $channel->{svg};
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
    system("find zipped_old -mtime +10 -exec rm {} \\;");
    system("find originals -mtime +10 -exec rm {} \\;");
}

sub syncFilesToS3
{
    say "Syncing with S3...";
    say "Syncing new...";
    system("s3cmd -m application/json --add-header='Content-Encoding: gzip' sync zipped/ s3://easytv.epg --delete-removed --acl-public");
    say "Syncing old...";
#    system("s3cmd -m application/json --add-header='Content-Encoding: gzip' sync zipped_old/ s3://tvguideplus --acl-public");
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
        my $live = "";
                
        if (/^(?!#)(.*) (.*) (.*)/)
        {
            $slug = $1;
            $xmltvid = $2;
            $live = $3;
        } elsif (/^(?!#)(.*) live=(.*)/) {
            $slug = $1;
            $live = $2;
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
            $channel{livelink} = $live;
            
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
            my $svg = $channel_input->{logos}->{svg};

            my $filter = $filters->{$slug};
            if (defined $filter) {
                my $filterName = $filter->{name};              
                my $filterXmltvid = $filter->{xmltvid};
                my $livelink = $filter->{livelink};
                
                if ($filterName eq "" && $filterXmltvid eq "" && $livelink eq "")
                {
                    # do nothing - channel should be skipped
                    say "Skipped $slug" if $verbose;
                } else {
                    # channel is OK - determine the right name + xmltvid
                    $channel{slug} = $slug;
                    $channel{countries} = $countries;
                    $channel{svg} = $svg;
                    if ($livelink ne "")
                    {
                        $channel{livelink} = $livelink;
                    }
                    if ($filterName ne "")
                    {
                        $channel{name} = $filterName;
                    } else {
                        $channel{name} = $honeybeeName;
                    }
                    $channel{xmltvid} = $honeybeeXmltvid;
                    if ($filterXmltvid ne "")
                    {
                        if ($filterXmltvid eq "old")
                        {
                            $filterXmltvid = $honeybeeXmltvid;
                        }
                        $channel{xmltvid_old} = $filterXmltvid;
                        $channel{xmltvid_new} = $honeybeeXmltvid;
                        $channel{xmltvid} = $filterXmltvid;
                    }
                    say "Channel = " . Dumper(\%channel) if $verbose;
                    push @channels, \%channel;
                }
            } else {
                if (scalar(@$countries) == 0 || !defined $svg || $svg eq "")
                {
                    # do nothing - channel should be skipped
                    say "Skipped $slug because no countries or svg" if $verbose;
                } elsif (!$onlylisted) {
                    $channel{slug} = $slug;
                    $channel{countries} = $countries;
                    $channel{name} = $honeybeeName;
                    $channel{xmltvid} = $honeybeeXmltvid;
                    $channel{svg} = $svg;
                    push @channels, \%channel;
                }
            }
        }
    } else {
        print STDERR $res->status_line, "\n";
    }
    
    say Dumper(\@channels) if $verbose;
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
            deleteOld($c->{xmltvid});
            handleChannel($c->{slug}, $c->{xmltvid}, $c->{xmltvid_old});
            checkLogo($c->{xmltvid}, $c->{svg});
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
    my($channel_slug, $xmltvid, $xmltvid_old) = @_;

    my $dt = DateTime->now;

    say "Fetching $channel_slug ($xmltvid)" if $verbose;

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
        
                        # year
                        my $year = 0;
                        if ($category eq "movie")
                        {
                            my $released = $p->{content}->{$category}->{released};
                            if (defined $released && $released =~ /(\d\d\d\d)-\d\d-\d\d/)
                            {
                                $year = $1;
                            }
                        } elsif ($category eq "series") {
                            my $aired = $p->{episode}->{aired};
                            if (defined $aired && $aired =~ /(\d\d\d\d)-\d\d-\d\d/)
                            {
                                $year = $1;
                            }
                        }
                        if ($year != 0)
                        {
                            $oneoutput{'year'} = $year;
                        }
        
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
                            if (checkGenres(["Documentary"], \@$genres))
                            {
                                $finalcat = "Dokumentar";
                            } else {
                                my $runtime = ($oneoutput{'stop'}-$oneoutput{'start'})/60;
                                if ($runtime > 10)
                                {
                                    $finalcat = "Film";
                                } else {
                                    $finalcat = "";
                                }
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
                        say Dumper(\%oneoutput) if $verbose;
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
                    if (defined $xmltvid_old)
                    {
                        my $jsonfilename_old = $xmltvid_old . "_" . $dt->ymd . ".js";                    
                        system("cp $zippedfullpath zipped_old/$jsonfilename_old" . ".gz");
                    }
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

sub checkLogo
{
    my($xmltvid, $svglogo) = @_;
    my $logopath = "logos/png/$xmltvid.png";
    
    say "checking logo for $xmltvid" if $verbose;
    if (! -e $logopath)
    {
        system("wget $svglogo -O logo.svg");
#        system("rm png/$xmltvid.png");
#        say "Converting to PNG";
        system("inkscape -z -e $logopath -w 1000 --export-background-opacity=0.0 logo.svg");
#        say "Scaling";
        system("mogrify -monitor -trim -resize 500x500 $logopath");
#        say "Squash";
        system("pngquant --quality=0-90 -v -f --ext .png $logopath");
    }
}

sub syncLogos
{
    say "Sync logos with S3";
    system("s3cmd sync logos/png/ s3://easytv.logos --delete-removed --acl-public");
}

sub deleteOld
{
    my ($xmltvid) = @_;

    my $dt = DateTime->now;
    $dt->subtract( days => 1 );

    for (my $i = 1; $i < 5; $i++)
    {
        my $date = $dt->ymd;
        my $basefile = $xmltvid . "_" . $date . ".js";
        deleteIfExists("originals/$basefile");
        deleteIfExists("zipped/$basefile.gz");
        deleteIfExists("zipped_old/$basefile.gz");
        $dt->subtract( days => 1 );
    }
}

sub deleteIfExists
{
    my ($path) = @_;
    
    if (-e $path)
    {
        system("rm $path");
    }
}
