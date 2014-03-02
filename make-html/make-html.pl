#!/usr/bin/perl
#
# Konvertiert die LUGS-Terminliste (im ASCII Format) in ein HTML-File
#
# (c) 1996-1998               Roland Alder
# (c) 2007-2008, 2011-2014    Steven Schubiger

use strict;
use warnings;
use lib qw(lib);

my $VERSION = '0.04';

#-----------------------
# Start of configuration
#-----------------------

#
# If you're looking for the template,
# it is contained below __DATA__ at the end
# of this script.
#

my $Config = {
    data_source => './termine.txt',
    html_file   => './index.phtml',
    colors      => {
       fremd         => 'a2eeff',	# blau/gruen
       treff         => '99ccff',	# ex http://www.zuerich.ch/
       seeland       => 'ffffbb',	# gelb
       aargau        => 'ffbbff',	# violett
       bern          => 'a5f6bb',	# gruen
       spec          => 'ff8a80',	# rot
       winti         => 'd6d6ce',	# ex http://www.stadt-winterthur.ch/
       innerschweiz  => '8abed7',	# ex http://www.luzern.ch/
       kreuzlingen   => 'f9f9f9',	# ehemals aargau (ex http://www.ag.ch/)
       stgallen      => 'e2b1a5',	# wie heisst diese Farbe? :)
       gnupingu      => 'ffd133',	# von http://www.gnupingu.ch/
       debian        => 'ffa500',	# orange
       hackerfunk    => '99b2cd',	# blau/grau
    },
    ical_dir    => 'ical',
};

#---------------------
# End of configuration
#---------------------

#-------------------
# Start of internals
#-------------------

{
    my $termine = LUGS::Termine::Liste->new;

    $termine->init;

    my ($html_before, $html_after) = $termine->extract_html;
    $termine->parse_template;

    my $fh = $termine->{fh}{out};

    print {$fh} $html_before;
    $termine->process_events;
    print {$fh} $html_after;

    $termine->cleanup;

    $termine->finalize;
}

package LUGS::Termine::Liste;

use constant true => 1;

use File::Copy qw(copy);
use File::Temp qw(tempfile);
use LUGS::Events::Parser ();

# Return a new instance of our class.
sub new
{
    my $class = shift;

    return bless {};
}

# Open files and retrieve the modification time.
sub init
{
    my $self = shift;

    $self->{mtime} = scalar localtime +(stat($Config->{data_source}))[9];

    open($self->{fh}{in}, '<', $Config->{html_file}) or die "Cannot open $Config->{html_file}: $!\n";
    ($self->{fh}{out}, $self->{tmp_file}) = tempfile(UNLINK => true);
}

# Close file handles.
sub cleanup
{
    my $self = shift;

    foreach my $handle (qw(in out)) {
        close($self->{fh}{$handle});
    }
}

# Copy the temporary file to the HTML file's location.
sub finalize
{
    my $self = shift;

    copy($self->{tmp_file}, $Config->{html_file})
      or die "Cannot copy $self->{tmp_file} to $Config->{html_file}: $!\n";
}

# Extract chunks before and after where the events get populated in.
sub extract_html
{
    my $self = shift;

    my $fh = $self->{fh}{in};
    my $html = do { local $/; <$fh> };

    my @regexes = (
        qr/^ (.+? \n<!-- \s*? TERMINE_BEGIN \s*? --> \s*? \n)/sx,
        qr/      \n(<!-- \s*? TERMINE_ENDE  \s*? --> .*)    $/sx,
    );

    my @chunks;
    foreach my $regex (@regexes) {
        push @chunks, $1 if $html =~ $regex;
    }

    return @chunks;
}

# Dump regular events formatted to the output handle.
sub process_events
{
    my $self = shift;

    my $parser = LUGS::Events::Parser->new($Config->{data_source});

    my $i;
    my %month_names = map { sprintf("%02d", ++$i) => $_ }
      qw(Januar Februar M&auml;rz April Mai Juni Juli
         August September Oktober November Dezember);

    my $seen ||= '';
    my $print_month = sub
    {
        my ($event) = @_;

        my $year  = $event->get_event_year;
        my $month = $event->get_event_month;
        my $day   = $event->get_event_day;

        if ($month ne $seen) {
            $seen = $month;
            $self->print_template('jahreszeit',
            {
                MONAT => $month_names{$month},
                JAHR  => $year,
            });
        }
    };

    $self->print_template('tabellenstart');
    $self->print_template('kopfdaten');

    while (my $event = $parser->next_event) {
        $print_month->($event);

        my $anchor = $event->get_event_anchor;

        $self->print_template('farbe',
        {
            FARBE => $Config->{colors}->{$event->get_event_color}
        });

        $self->print_template('anker/wann',
        {
            ANKER     => $anchor,
            WOCHENTAG => $event->get_event_weekday,
            TAG       => $event->get_event_day,
        });

        $event->get_event_time
          ? $self->print_template('zeit',
            {
                UHRZEIT => $event->get_event_time,
            })
          : $self->print_template('blank');

        $event->get_event_responsible
          ? $self->print_template('verantwortlich',
            {
                WER => $event->get_event_responsible,
            })
          : $self->print_template('blank');

        $self->print_template('titel',
        {
            BEZEICHNUNG => $event->get_event_title,
        });

        $event->get_event_location
          ? $self->print_template('standort',
            {
                STANDORT => $event->get_event_location,
            })
          : ();

        $event->get_event_more
          ? $self->print_template('infos',
            {
                INFORMATIONEN => $event->get_event_more,
            })
          : ();

        my $ics_file = "$anchor.ics";
        my $ics_link = join '/', ($Config->{ical_dir}, $ics_file);

        $self->print_template('ical',
        {
            LINK => $ics_link,
        });

        $self->print_raw_html('</td></tr>');
    }

    $self->print_template('tabellenende');
    $self->print_template('fussnoten',
    {
        AENDERUNG => $self->{mtime},
    });
}

# Parse the template as outlined below __DATA__ and create
# a lookup map.
sub parse_template
{
    my $self = shift;

    my $template = do { local $/; <DATA> };

    $self->{template} = [ map { s/\n{2,}$/\n/; $_ }        #  # description
                          grep /\S/,                       #  -
                          split /\# \s+? .+? \s+? -\n/x,
                          $template ];
      my @descriptions;
    push @descriptions, $1 while $template =~ /\# \s+? (.+?) \s+? -\n/gx;

    my $i;
    $self->{lookup} = { map { $_ => $i++ } @descriptions };
}

# Look up the template item, substitute it with the data
# given and print it to the output handle.
sub print_template
{
    my $self = shift;
    my ($keyword, $data) = @_;

    return unless exists $self->{lookup}->{$keyword};

    my $item = $self->{template}->[$self->{lookup}->{$keyword}];

    my %markers = (
        begin => '[%',
        end   => '%]',
    );
    foreach my $marker ($markers{begin}, $markers{end}) {
        $marker = qr/\Q$marker\E/;
    }

    foreach my $name (keys %$data) {
        $item =~ s/$markers{begin}
                     \s*?
                       $name
                     \s*?
                   $markers{end}
                  /$data->{$name}/gx;
    }

    my $fh = $self->{fh}{out};
    print {$fh} $item;
}

# Print raw HTML to the output handle.
sub print_raw_html
{
    my $self = shift;
    my ($html) = @_;

    my $fh = $self->{fh}{out};
    print {$fh} $html, "\n";
}

#-----------------
# End of internals
#-----------------

#
# Do not change the data descriptions within '# <name>' without
# adjusting the code accordingly; furthermore, the hyphen '-'
# is required and two trailing newlines at the end of the
# template item, too.
#

__DATA__

# tabellenstart
-
<table border=0 cellpadding=1 cellspacing=2>

# kopfdaten
-
<tr><td>&nbsp;</td></tr>
<tr><td colspan=4 align=left><h2>Definitive Daten</h2></td></tr>
<tr><th align=left>Tag</th><th align=left>Zeit</th><th align=left>Verantwortlich</th><th align=left>Anlass, Thema</th></tr>

# jahreszeit
-
<tr><th align=left colspan=3><br><font size="+1">[% MONAT %] [% JAHR %]</font></th></tr>

# anker
-
<a name="[% WERT %]"></a>

# farbe
-
<tr bgcolor="#[% FARBE %]">

# anker/wann
-
<td valign=top><a name="[% ANKER %]"></a>[% WOCHENTAG %], [% TAG %].</td>

# zeit
-
<td valign=top>[% UHRZEIT %]</td>

# verantwortlich
-
<td valign=top>[% WER %]</td>

# titel
-
<td valign=top><b>[% BEZEICHNUNG %]</b>

# standort
-
<br><font size=-1>[% STANDORT %]</font>

# infos
-
<br>[% INFORMATIONEN %]

# ical
-
<td valign=top><a href="[% LINK %]">iCal</a></td>

# tabellenende
-
</table>

# fussnoten
-
<p>
<font size="-1">Alle Angaben ohne Gew&auml;hr, letzte &Auml;nderung der Terminliste: [% AENDERUNG %]</font>

# blank
-
<td>&nbsp;</td>
