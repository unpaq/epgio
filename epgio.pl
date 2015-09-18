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

my %programs;
my %programs2;
my $endpoint = "https://api.epg.io/v1";
my $ua = LWP::UserAgent->new();

system("rm output/*");

open(my $in, "<", "channels.conf") or die "Can't open channels.conf: $!";

while (<$in>)
{
    if (/^(?!#)(.*) (.*)/)
    {
        my $channel_slug;
        my $xmltvid;

        $channel_slug = $1;
        $xmltvid = $2;
        my $dt = DateTime->now;

        say "Fetching $channel_slug ($xmltvid)";

        for (my $i = 1; $i < 10; $i++)
        {
            my $date = $dt->ymd;
            my $url = "$endpoint/schedule/listings/$date/$channel_slug.json?api_key=$api_key";
            print "URL = $url";
            my $req = new HTTP::Request GET => $url;
            my $res = $ua->request($req);
            if ($res->is_success)
            {
                my %output;
                my @pout;

                my $content = $res->content;
                my $json = decode_json( $content );
                my $programs = $json->{channels}[0]->{programmes};
                say " - " . scalar @$programs . " programs found.";
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
                    my $desc = $p->{programme}->{description};
                    if (defined $desc && $desc ne '')
                    {
                        my %description;
                        $description{''} = $desc;
                        $oneoutput{'desc'} = \%description;
                    }
                    $dt = DateTime::Format::ISO8601->parse_datetime($p->{programme}->{start});
                    $oneoutput{'start'} = $dt->epoch();
                    $dt = DateTime::Format::ISO8601->parse_datetime($p->{programme}->{stop});
                    $oneoutput{'stop'} = $dt->epoch();
                    
                    # id
                    my $epgio_id = $p->{programme}->{id};
                    $oneoutput{'id'} = $epgio_id;

                    # poster
                    my $poster = $p->{series}->{fanart}->{original};
                    if (defined $poster && $poster ne '')
                    {
                        $oneoutput{'poster'} = $poster;
                    }

                    # imdb_id
                    my $imdb_id = $p->{series}->{external_ids}->{imdb_id};
                    if (defined $imdb_id && $imdb_id ne '')
                    {
                        $oneoutput{'imdb_id'} = $imdb_id;
                    }

                    # tvdb_id
                    my $tvdb_id = $p->{series}->{external_ids}->{tvdb_id};
                    if (defined $tvdb_id && $tvdb_id ne '')
                    {
                        $oneoutput{'tvdb_id'} = $tvdb_id;
                    }

                    my $category = $p->{series}->{category};
                    my $finalcat = "";
                    if ($category eq "series")
                    {
                        my $genres = $p->{series}->{genres};
                        $oneoutput{'origGenres'} = \@$genres;
                                                
                            if (checkGenres(["News"], \@$genres))
                            {
                                $finalcat = "Nyheder";
                            } elsif (checkGenres(["Kids"], \@$genres)) {
                                $finalcat = "Børn & Ungdom";
                            } elsif (checkGenres(["Entertainment", "Lifestyle"], \@$genres)) {
                                $finalcat = "Underholdning";
                            } elsif (checkGenres(["Reality"], \@$genres)) {
                                $finalcat = "Reality";
                            } elsif (checkGenres(["Mini-Series"], \@$genres)) {
                                $finalcat = "Serier";
                            } elsif (checkGenres(["Music", "Musical"], \@$genres)) {
                                $finalcat = "Musik";
                            } elsif (checkGenres(["Animals", "Nature", "Home and Garden"], \@$genres)) {
                                $finalcat = "Natur";
                            } elsif (checkGenres(["History", "Biography", "Documentary"], \@$genres)) {
                                $finalcat = "Dokumentar";
                            } elsif (checkGenres(["Comedy", "Drama"], \@$genres)) {
                                $finalcat = "Serier";
                            } else {
                                #say $p->{name}->{title} . " " . Dumper(\@$genres);
                            }
                    } elsif ($category eq "sports") {
                        $finalcat = "Sport";
                    } elsif ($category eq "movie") {
                        $finalcat = "Film";
                    }
                    my %cathash;
                    my @catarray;
                    push @catarray, $finalcat;
                    $cathash{'en'} = \@catarray;
                    $oneoutput{'category'} = \%cathash;
                    
                    my $episode = $p->{'episode'}->{number};
                    
                    if (defined $episode && $episode ne '')
                    {
                        my %episodeNum;
                        my $season = $p->{'episode'}->{'season_number'};
                        if (defined $season && $season ne '')
                        {
                            $episodeNum{'xmltv_ns'} = $season . "." . $episode-1 . ".";
                        } else {
                            $episodeNum{'xmltv_ns'} = "." . $episode-1 . ".";
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
#                say Dumper(\%l1struct);

                my $json_text = JSON->new->utf8(1)->encode(\%l1struct);
#                say $json_text;
                my $jsonoutf = "output/" . $xmltvid . "_" . $dt->ymd . ".js";
                open(my $out, ">", $jsonoutf) or die "Can't open $jsonoutf: $!";
                print $out $json_text;
                close $out;
                system("gzip -f $jsonoutf"); 
                system("mv $jsonoutf" . ".gz /var/local/nonametv/json_staging/");
            } else {
                print STDERR $res->status_line, "\n";
            }

            $dt->add( days => 1 );
#            last;
        }
    }
}

close $in;

system("s3cmd -m application/json --add-header='Content-Encoding: gzip' sync /var/local/nonametv/json_staging/ s3://tvguideplus --delete-removed --acl-public");

sub imdbRating
{
    my($searchGenres, $objectGenres) = @_;

#https://api.epg.io/v1/series/5504168163686170e7473306/ratings?api_key=

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
