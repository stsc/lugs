#!/usr/bin/perl
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
# Author: Steven Schubiger <stsc@refcnt.org>
# Last modified: Wed 09 Jun 2021 10:05:08 PM CEST

use strict;
use warnings;
use lib qw(lib);

my $VERSION = '0.06';

my $Config = {
    base_url => 'https://www.lugs.ch/lugs/termine',
    input    => './termine.txt',
    ical_dir => 'ical',
    offset   => undef,
};

{
    mkdir $Config->{ical_dir} unless -e $Config->{ical_dir};

    my $ical = LUGS::Termine::ICal->new;
    $ical->process_events;
}

package LUGS::Termine::ICal;

use constant true  => 1;
use constant false => 0;

use Data::ICal ();
use Data::ICal::Entry::Event ();
use Date::ICal ();
use DateTime ();
use File::Spec ();
use LUGS::Events::Parser ();

sub new
{
    my $class = shift;

    return bless {};
}

sub process_events
{
    my $self = shift;

    my $parser = LUGS::Events::Parser->new($Config->{input}, {
        filter_html  => true,
        tag_handlers => {
            'a href' => [ {
                rewrite => '$TEXT',
                fields  => [ qw(location) ],
            }, {
                rewrite => '$TEXT ($HREF)',
                fields  => [ qw(more) ],
            } ],
        },
        strip_text => [ 'mailto:' ],
    });

    while (my $event = $parser->next_event) {
        my $year  = $event->get_event_year;
        my $month = $event->get_event_month;
        my $day   = $event->get_event_day;

        my %time;

        if ($event->get_event_time =~ /^(\d+:\d+) (?:\s+ - \s+ (\d+:\d+))?$/x) {
            @time{qw(start_hour start_min)} = split /\:/, $1;
            if ($2) {
                @time{qw(end_hour end_min)} = split /\:/, $2;
            }
            else {
                @time{qw(end_hour end_min)} = @time{qw(start_hour start_min)};
            }
        }
        else {
            %time = map { $_ => 0 } qw(start_hour start_min end_hour end_min);
        }

        $self->{calendar} = Data::ICal->new;
        my $ical_event    = Data::ICal::Entry::Event->new;

        my $location = $event->get_event_location;
        my $summary  = $event->get_event_title;
        my $anchor   = $event->get_event_anchor;
        my $more     = $event->get_event_more;

        $location =~ s/\(.+?\)//g;
        $more =~ s/<.+?>//g if defined $more;

        my $get_offset = sub
        {
            my ($hour, $minute) = @_;
            return $Config->{offset} if $Config->{offset};
            my $dt = DateTime->new(
                year      => $year,
                month     => $month,
                day       => $day,
                hour      => $hour,
                minute    => $minute,
                time_zone => 'Europe/Zurich',
            );
            return $dt->is_dst() ? '+0200' : '+0100';
        };
        $ical_event->add_properties(
            dtstamp => Date::ICal->new->ical,
            dtstart => Date::ICal->new(
                year   => $year,
                month  => $month,
                day    => $day,
                hour   => $time{start_hour},
                min    => $time{start_min},
                sec    => 00,
                offset => $get_offset->(@time{qw(start_hour start_min)}),
            )->ical,
            dtend => Date::ICal->new(
                year   => $year,
                month  => $month,
                day    => $day,
                hour   => $time{end_hour},
                min    => $time{end_min},
                sec    => 00,
                offset => $get_offset->(@time{qw(end_hour end_min)}),
            )->ical,
            location    => $location,
            summary     => $summary,
            defined $more ? (
            description => $more,
            ) : (),
            uid         => "${anchor}\@lugs.ch",
            url         => join '#', ($Config->{base_url}, $anchor),
        );

        $self->{calendar}->add_entry($ical_event);
        $self->save_ical($anchor);
    }
}

sub save_ical
{
    my $self = shift;
    my ($file) = @_;

    my $ics_file = $file . '.ics';
    my $ics_path = File::Spec->catfile($Config->{ical_dir}, $ics_file);

    open(my $fh, '>', $ics_path) or die "Cannot write $ics_path: $!\n";
    print {$fh} do { local $_ = $self->{calendar}->as_string;
#                     s/\n/\r\n/g;
                     $_ };
    close($fh);
}
