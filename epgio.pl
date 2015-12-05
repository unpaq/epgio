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

my $channel_id = $ARGV[0];
my $xmlid = $ARGV[1];
my $testmode = 0;

if (defined $channel_id)
{
    if (!defined $xmlid)
    {
        $testmode = 1;
        $xmlid = "test.test.dk";
    }
}

open(my $api_key_file, "<", "apikey.conf") or die "Can't open apikey.conf: $!";
my $api_key = <$api_key_file>;
chomp($api_key);
close $api_key_file;

my $endpoint = "https://api.honeybee.it/v2";
my $ua = LWP::UserAgent->new();
my %ratings;

my %cattrans;
my %channeltrans;
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

if ($testmode == 0)
{
    system("rm output/*");
}

if (!defined $channel_id)
{
    open(my $in, "<", "channels.conf") or die "Can't open channels.conf: $!";
	while (<$in>)
	{
		if (/^(?!#)(.*) (.*)/)
		{
			handleChannel($1, $2);
		}
	}
	close $in;
} else {
	handleChannel($channel_id, $xmlid);
}

if ($testmode == 0)
{
    system("s3cmd -m application/json --add-header='Content-Encoding: gzip' sync /var/local/nonametv/json_staging/ s3://tvguideplus --delete-removed --acl-public");
}

# The end

sub handleChannel
{
    my($channel_slug, $xmltvid) = @_;

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
			my $programs = $json; #->{channels}[0]->{programmes};
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

				my $finalcat = "";
				if ($category eq "series")
				{
					my $genres = $p->{content}->{$category}->{genres};
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
					$finalcat = "Film";
				}
				if ($finalcat eq "")
				{
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
#				if ($finalcat eq "")
#				{
#					my $genres = $p->{series}->{genres};
#					say "T: " . $p->{name}->{title} . " -- " . join(", ", @$genres);
#				}
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

			my $json_text = JSON->new->utf8(1)->encode(\%l1struct);
#                say $json_text;
			if ($testmode == 0)
			{
				my $jsonoutf = "output/" . $xmltvid . "_" . $dt->ymd . ".js";
				open(my $out, ">", $jsonoutf) or die "Can't open $jsonoutf: $!";
				print $out $json_text;
				close $out;
				system("gzip -f $jsonoutf"); 
				system("mv $jsonoutf" . ".gz /var/local/nonametv/json_staging/");
			} else {
				say Dumper(\%l1struct);                    
			}
		} else {
			print STDERR $res->status_line, "\n";
		}

		$dt->add( days => 1 );
	}
}

sub imdbRating
{
    my($results) = @_;
    my $rating = 0;
#    my $lookup = $ratings{$slug};

#    if (defined $lookup)
#    {
#        $rating = $lookup;
#    } else {
#        my $url = "$endpoint/series/$slug/ratings.json?api_key=$api_key";
#        my $req = new HTTP::Request GET => $url;
#        my $res = $ua->request($req);
#        if ($res->is_success)
#        {
#            my $json = decode_json( $res->content );
#            my $results = $json->{results};
#            say "Ratings = " . Dumper(@$results);
            foreach my $r (@$results)
            {
                if ($r->{provider} eq "imdb")
                {
#                    if (defined $r->{votes} && $r->{votes} > 1000)
#                    {
                        $rating = 0+$r->{rating};
#                    }
#                    $ratings{$slug} = $rating;
                    last;
                }
            }
#        }
#    }

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
