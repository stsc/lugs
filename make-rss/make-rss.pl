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
# Last modified: Wed Jul 24 14:45:23 CEST 2013

use strict;
use warnings;
use lib qw(lib);

my $VERSION = '0.01';

my $Config = {
    base_url  => 'http://www.lugs.ch/lugs/termine/',
    language  => 'de',
    input     => './termine.txt',
    output    => './termine.rss',
    title     => 'LUGS Terminliste',
    webmaster => 'www@lugs.ch',
};

{
    my $rss = LUGS::Termine::RSS->new;

    $rss->init;
    $rss->process_content;
    $rss->save_rss;
}

package LUGS::Termine::RSS;

use constant true => 1;

use LUGS::Events::Parser ();
use XML::RSS::SimpleGen ();

sub new
{
    my $class = shift;

    return bless {};
}

sub init
{
    my $self = shift;

    $self->{rss} = XML::RSS::SimpleGen->new($Config->{base_url}, $Config->{title});

    $self->{rss}->allow_duplicates(true);
    $self->{rss}->language($Config->{language});
    $self->{rss}->webmaster($Config->{webmaster});
}

sub process_content
{
    my $self = shift;

    my $parser = LUGS::Events::Parser->new($Config->{input});

    while (my $event = $parser->next_event) {
        my $year  = $event->get_event_year;
        my $month = $event->get_event_month;
        my $day   = $event->get_event_day;

        my $date      = join '.',  ($day, $month, $year);
        my $full_date = join ', ', ($event->get_event_weekday, $date);

        my $title = join ', ', ($full_date, $event->get_event_time, $event->get_event_title);
        my $desc  = join ' ',  ($event->get_event_location, $event->get_event_more || ());

        $self->save_item($Config->{base_url}, $event->get_event_anchor, $title, $desc);
    }
}

sub save_item
{
    my $self = shift;
    my ($url, $anchor, $title, $desc) = @_;

    $self->{rss}->item("$url#$anchor", $title, $desc);
}

sub save_rss
{
    my $self = shift;

    $self->{rss}->save($Config->{output});
}
