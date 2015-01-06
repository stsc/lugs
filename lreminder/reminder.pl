#!/usr/bin/perl

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
# Last modified: Tue Jan  6 14:37:04 CET 2015

use strict;
use warnings;
use lib qw(lib);
use constant true  => 1;
use constant false => 0;

use DateTime ();
use DBI ();
use Encode qw(encode);
use File::Basename ();
use File::Spec ();
use FindBin qw($Bin);
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case);
use Hook::Output::File ();
use LUGS::Events::Parser ();
use Mail::Sendmail qw(sendmail);
use Text::Wrap::Smart::XS qw(fuzzy_wrap);
use URI ();
use WWW::Mechanize ();

my $VERSION = '0.50';

#-----------------------
# Start of configuration
#-----------------------

my $Config = {
    events_url => 'http://www.lugs.ch/lugs/termine/termine.txt',
    form_url   => 'http://lists.lugs.ch/reminder.cgi',
    mail_from  => 'reminder@lugs.ch',
    dbase_name => '<hidden>',
    dbase_user => '<hidden>',
    dbase_pass => '<hidden>',
};

#---------------------
# End of configuration
#---------------------

my $dbh  = DBI->connect("dbi:mysql(RaiseError=>1):$Config->{dbase_name}", $Config->{dbase_user}, $Config->{dbase_pass});
my $file = File::Spec->catfile('tmp', (URI->new($Config->{events_url})->path_segments)[-1]);

my ($test, $run) = (false, false);

{
    getopts(\$test, \$run);
    my $hook = Hook::Output::File->redirect(
        stdout => File::Spec->catfile($Bin, 'stdout.out'),
        stderr => File::Spec->catfile($Bin, 'stderr.out'),
    );
    fetch_and_write_events();
    process_events();
}

sub getopts
{
    my ($test, $run) = @_;

    GetOptions(test => $test, run => $run) or exit;

    if (not $$test || $$run) {
        die "$0: neither --test nor --run specified, exiting\n";
    }
    elsif ($$test && $$run) {
        die "$0: both --test and --run specified, exiting\n";
    }
    return; # --test or --run specified
}

sub fetch_and_write_events
{
    my $mech = WWW::Mechanize->new;
    my $http = $mech->get($Config->{events_url});

    open(my $fh, '>', $file) or die "Cannot open $file for writing: $!\n";
    print {$fh} $http->content;
    close($fh);
}

sub init
{
    my ($parser) = @_;

    $$parser = LUGS::Events::Parser->new($file, {
        filter_html  => true,
        tag_handlers => {
            'a href' => [ {
                rewrite => '$TEXT - <$HREF>',
                fields  => [ qw(responsible) ],
            }, {
                rewrite => '$TEXT - $HREF',
                fields  => [ qw(location more) ],
            } ],
        },
        purge_tags => [ qw(location responsible more) ],
        strip_text => [ 'mailto:' ],
    });
    unlink $file;
}

sub process_events
{
    my $parser;
    init(\$parser);

    while (my $event = $parser->next_event) {
        my %event = (
            year  => $event->get_event_year,
            month => $event->get_event_month,
            day   => $event->get_event_day,
            color => $event->get_event_color,
        );

        my %sth;

        $sth{subscribers} = $dbh->prepare('SELECT mail, mode, notify FROM subscribers');
        $sth{subscribers}->execute;

        while (my $subscriber = $sth{subscribers}->fetchrow_hashref) {
            next unless $subscriber->{mode} == 2;

            $sth{subscriptions} = $dbh->prepare('SELECT * FROM subscriptions WHERE mail = ?');
            $sth{subscriptions}->execute($subscriber->{mail});

            my $subscriptions = $sth{subscriptions}->fetchrow_hashref;
            next unless $subscriptions->{$event{color}};

            my $notify = DateTime->now(time_zone => 'Europe/Zurich');

            $subscriber->{notify} ||= 0;

            $notify->add(days => $subscriber->{notify});

            if ($event{year}  == $notify->year
             && $event{month} == $notify->month
             && $event{day}   == $notify->day
            ) {
                send_mail($event, $subscriber->{mail});
            }
        }
    }
}

sub send_mail
{
    my ($event, $mail_subscriber) = @_;

    my $year        = $event->get_event_year;
    my $month       = $event->get_event_month;
    my $simple_day  = $event->get_event_simple_day;
    my $wday        = $event->get_event_weekday;
    my $time        = $event->get_event_time;
    my $title       = $event->get_event_title;
    my $color       = $event->get_event_color;
    my $location    = $event->get_event_location;
    my $responsible = $event->get_event_responsible;
    my $more        = $event->get_event_more || '';

    wrap_text(\$more);
    chomp $more;
    wrap_text(\$location);

    my $i;
    my %month_names = map { sprintf('%02d', ++$i) => $_ }
      qw(Januar Februar Maerz April Mai Juni Juli August
         September Oktober November Dezember);

    my $month_name = $month_names{$month};

my $message = (<<"MSG");
Wann:\t$wday, $simple_day. $month_name $year, $time Uhr
Was :\t$title
Wo  :\t$location
Wer :\t$responsible
Info:\t$more

Web Interface:
$Config->{form_url}

${\info_string()}
MSG

    if ($run) {
        sendmail(
            From    => $Config->{mail_from},
            To      => $mail_subscriber,
            Subject => encode('MIME-Q', "LUGS Reminder - $title"),
            Message => $message,
        ) or die "Cannot send mail: $Mail::Sendmail::error";
    }
    elsif ($test) {
        printf "[%s] <$mail_subscriber> ($color)\n", scalar localtime;
    }
}

sub wrap_text
{
    my ($text) = @_;

    return unless length $$text;

    my @chunks = fuzzy_wrap($$text, 70);

    my $wrapped;
    foreach my $chunk (@chunks) {
        $wrapped .= ' ' x (defined $wrapped ? 8 : 0);
        $wrapped .= "$chunk\n";
    }
    chomp $wrapped;

    $$text = $wrapped;
}

sub info_string
{
    my $script = File::Basename::basename($0);
    my $modified = localtime((stat($0))[9]);

    $modified =~ s/(?<=\b) (?:\d{2}\:?){3} (?=\b)//x;
    $modified =~ s/\s{2,}/ /g;

    my $info = <<"EOT";
-- 
running $script v$VERSION - last modified: $modified
EOT
    return do { local $_ = $info; chomp while /\n$/; $_ };
}
