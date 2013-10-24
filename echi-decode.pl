#!/usr/bin/perl

# ECHI decoder script (c) 2008-2013 Alex Tokarev <tokarev@cpan.org>
#
# Usage: echi-decode.pl <binary input file> <csv output file>
#
# Version log:
#
# 1.72: Added an option to specify string delimiter character
#       Fixed a bug with date format command line option handling
# 1.71: Fixed a bug with R17 header version
# 1.7:  Log is now written to STDERR instead of STDOUT, to accommodate
#       for optional data output to STDOUT. Added command line options.
#       Updated to CMS R17 data structures (not tested yet).
#       Kudos to Alexey Safonov for R17 patch.
# 1.6:  Updated to accommodate for CMS 16.3 changes.
# 1.5:  Updated for CMS R16. Hopefully in full.
# 1.4:  Fixed incorrect field length definition for R11 and R3V8 ECHI formats
# 1.3:  Fixed bug with double timezone conversion
# 1.2:  Added an experimental fix for CMS DURATION/SEGSTART fields bug
# 1.1:  Completely rewrote parsing code, optimized it for speed and size
# 1.0:  Initial release
#

#
# Configurable parameters. Should only be set once under normal
# circumstances.
#

#
# Be verbose, print a line for every call record. Use -v and -q
# command line options to override.
#
my $VERBOSE = 1;

#
# Print header line with field names? 1 means Yes, 0 means No.
# If you don't want header line you may just comment this variable out.
# Use -p and -n command line options to override.
#
my $PRINT_HEADER = 1;

#
# Date format for SEGSTART and SEGSTOP fields, in strftime format.
# To have date/time output in UNIX format, set this to an empty string.
# For conventional U.S. format use %c, man strftime for more information.
# For this field to be enclosed in double quotes put them in the format
# string.
# Use -f command line option to override.
#
#my $DATE_FORMAT => '"%c"';
my $DATE_FORMAT = '"%d.%m.%Y %H:%M:%S"';

#
# String field delimiter character, by default a double quote (").
# In CSV file format, it is commonly expected to have string fields
# enclosed in a delimiter characters, like "foo", as opposed to numeric
# fields that usually are not enclosed, like 0.
# Note that this setting *does not* affect date fields - see $DATE_FORMAT
# above.
# In some cases it may be desirable not to enclose string fields, too;
# set this to an empty string '' to achieve that effect.
# Use -s command line option to override.
#
my $STRING_DELIMITER = '"';

############################################################################
#
# PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE!
# Unless you know what you're doing, that is.
#
############################################################################

use strict;
use warnings;

use Getopt::Std qw/ getopts /;
use POSIX       qw/ strftime /;

sub logit {
    print STDERR join ' ', (scalar localtime), @_;
}

sub dieit {
    logit @_;
    exit 1;
}

#
# Data record formats. There are all documented ECHI format versions
# so there's no need to mess with them.
#

my %ECHI = eval do { local $/; <DATA> }
    or die "Can't eval DATA: $@\n";

$\ = "\n";

{
    my %opt;
    
    getopts 'vqpnhf:s:', \%opt;

    # Be quiet if -q, verbose if -v, or fall back to config
    $VERBOSE = $opt{q} ? 0 : $opt{v} ? 1 : $VERBOSE;
    
    # Don't print header if -n, print if -p, or fall back
    $PRINT_HEADER = $opt{n} ? 0 : $opt{p} ? 1 : $PRINT_HEADER;

    # Command line trumps configured date format
    $DATE_FORMAT = $opt{f} if defined $opt{f};

    # String delimiter can be overridden, too
    $STRING_DELIMITER = $opt{s} if defined $opt{s};
}

if ($#ARGV < 1) {
  die <<"END";
Usage: $0 [parameters] <input chr file> <csv file>

Parameters:
-v -- be verbose, print diagnostic line per every chr record
-q -- be quiet even despite \$VERBOSE variable or -v parameter set
-p -- print CSV header line, listing all column names
-n -- don't print header, takes precedence over variable or -p
-f <format> -- set date format, enclose in '' if there are spaces
-s <char> -- set string delimiter character, default is qouble quote (")

Input and output file names can be dashes (-), in which case STDIN
and STDOUT are used, respectively.

END
};
                                                              
logit "$0 started" if $VERBOSE;

my ($input_file, $output_file) = @ARGV;

# Two-argument form is used to handle STDIN/STDOUT
open my $input, "<$input_file" or
    dieit "Can't open input file $input_file for reading: $!";

open my $output, ">$output_file" or
    dieit "Can't open output file $output_file for writing: $!";

binmode $input;

my ($ver, $seq) = do {
    read($input, my $buf, 8);
    unpack("V2", $buf);
};

die "Unsupported file version $ver, can't process\n"
    unless exists $ECHI{$ver};

logit "Processing file $ARGV[0], version $ver, sequence $seq" if $VERBOSE;

# Readability trumps brevity any time
my $processed     = 0;
my $echi_format   = $ECHI{$ver};
my $header        = $echi_format->{header};
my $chunk_length  = $echi_format->{length};
my $unpack_format = $echi_format->{format};
my $bits_index    = $echi_format->{bits}->{index};
my $bits_format   = $echi_format->{bits}->{format};
my $signed        = $echi_format->{signed};
my $strstart      = $echi_format->{strstart};
my $strstop       = $echi_format->{strstop};
my $segment       = $echi_format->{segment};

print $output $header if $PRINT_HEADER;

while( read $input, my $buf, $chunk_length ) {
    my @data = unpack $unpack_format, $buf;
    my $bits = unpack $bits_format, $buf;
    
    splice @data, $bits_index, 0, split //, $bits;

    #
    # Fix for a weird DURATION/SEGSTART problem
    #

    if ($data[5] > 0x7fffffff) {
        $data[5] = -unpack 'l', pack 'L', $data[5];

        # Crude hack but will have to do for now.
        # Not sure if there will be any changes to this logic after R16.
        $data[6] = $data[($ver >= 16 ? 8 : 7)] - $data[5];
    };
  
    if ($DATE_FORMAT) {
        for (my $i = 6; $i < ($ver >= 16 ? 10 : 8); $i++) {
            $data[$i] = strftime $DATE_FORMAT, gmtime $data[$i];
        }
    };

    foreach my $index (@$signed) {
        $data[$index] = unpack 's', pack 'S', $data[$index];
    };

    for (my $i = $strstart; $i <= ($strstop || $#data); $i++) { 
        $data[$i] = $STRING_DELIMITER . $data[$i] . $STRING_DELIMITER; 
    };

    dieit "Cannot write to file: $!"
        unless print $output join ',', @data;

    $processed++;

    my $callid  = $data[0];
    my $segment = $data[$segment];
    
    logit "Processed record $processed, Call ID $callid, Segment $segment"
        if $VERBOSE;
};

logit "File $ARGV[0] processed successfully, found $processed records."
    if $VERBOSE;

close $input;
close $output;

exit 0;

__DATA__
(
    2  =>		# CMS R3V4 and below
    {
        length   => 189,
        header   => join ',', qw(
                        CALLID          ACWTIME         ANSHOLDTIME
                        CONSULTTIME     DISPTIME        DURATION
                        SEGSTART        SEGSTOP         TALKTIME
                        DISPIVECTOR     DISPSPLIT       FIRSTIVECTOR
                        SPLIT1          SPLIT2          SPLIT3
                        TKGRP           ASSIST          AUDIO
                        CONFERENCE      DA_QUEUED       HOLDABN
                        MALICIOUS       OBSERVINGCALL   TRANSFERRED
                        ACD             DISPOSITION     DISPPRIORITY
                        HELD            SEGMENT         EVENT1
                        EVENT2          EVENT3          EVENT4
                        EVENT5          EVENT6          EVENT7
                        EVENT8          EVENT9          DISPVDN
                        EQLOC           FIRSTVDN        ORIGLOGIN
                        ANSLOGIN        LASTOBSERVER    DIALED_NUM
                        CALLING_PTY     LASTCWC
                    ),
        format   => 'V9 v7 x1 C14 A6 A10 A6' . 'A10'x3 . 'A25 A13 x17 A17',
        bits     => { index => 16, format => '@50b8' },
        signed   => [ 10, 12, 13, 14 ],
        segment  => 28,
        strstart => 37
    },

  3  => 	# CMS R3V5
  {
    length => 210,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTOP,TALKTIME,DISPIVECTOR,DISPSPLIT,FIRSTIVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,DISPOSITION,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II',
    format => 'V9 v7 x2 C17 A6 A10 A6' . 'A10'x3 . 'A25 A13' . 'A17'x3,
    bits => {index => 16, format => '@50b9'},
    signed => [10, 12, 13, 14],
    segment => 29,
    strstart => 41
  },

  4  =>		# CMS R3V6
  {
    length => 225,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTOP,TALKTIME,NETINTIME,ORIGHOLDTIME,DISPIVECTOR,DISPSPLIT,FIRSTIVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,DISPOSITION,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,UCID,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II',
    format => 'V11 v7 x2 C17 A21 A6 A10 A6' . 'A10'x3 . 'A25 A13' . 'A17'x2 . 'A3',
    bits => {index => 18, format => '@58b9'},
    signed => [12, 14, 15, 16],
    segment => 31,
    strstart => 43
  },

  5  => 	# CMS R3V8
  {
    length => 233,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTOP,TALKTIME,NETINTIME,ORIGHOLDTIME,DISPIVECTOR,DISPSPLIT,FIRSTIVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,EQ_LOCID,ORIG_LOCID,ANS_LOCID,OBS_LOCID,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,DISPOSITION,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,UCID,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II',
    format => 'V11 v11 x2 C17 A21 A6 A10 A6' . 'A10'x3 . 'A25 A13' . 'A17'x2 . 'A3',
    bits => {index => 22, format => '@66b9'},
    signed => [12, 14, 15, 16],
    segment => 35,
    strstart => 48
  },

  11 =>		# CMS R11
  {
    length => 322,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTOP,TALKTIME,NETINTIME,ORIGHOLDTIME,DISPIVECTOR,DISPSPLIT,FIRSTIVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,EQ_LOCID,ORIG_LOCID,ANS_LOCID,OBS_LOCID,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,DISPOSITION,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,UCID,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II,CWC1,CWC2,CWC3,CWC4,CWC5',
    format => 'V11 v11 x2 C17 A21 A8 A10 A8' . 'A10'x3 . 'A25 A13' . 'A17'x2 . 'A3' . 'A17'x5,
    bits => {index => 22, format => '@66b9'},
    signed => [12, 14, 15, 16],
    segment => 35,
    strstart => 48
  },

  12 =>		# CMS R12 to R15
  {
    length => 493,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTOP,TALKTIME,NETINTIME,ORIGHOLDTIME,QUEUETIME,RINGTIME,DISPIVECTOR,DISPSPLIT,FIRSTVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,EQ_LOCID,ORIG_LOCID,ANS_LOCID,OBS_LOCID,UUI_LEN,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,DISPOSITION,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,UCID,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II,CWC1,CWC2,CWC3,CWC4,CWC5,VDN2,VDN3,VDN4,VDN5,VDN6,VDN7,VDN8,VDN9,ASAI_UUI',
    format => 'V13 v12 x2 C17 A21 A8 A10 A8' . 'A10'x3 . 'A25 A13 A17 A17 A3' . 'A17'x5 . 'A8'x8 . 'A96',
    bits => {index => 25, format => '@76b9'},
    signed => [14, 16, 17, 18],
    segment => 38,
    strstart => 51
  },

  16 =>		# CMS R16 and above
  {
    length => 615,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTART_UTC,SEGSTOP,SEGSTOP_UTC,TALKTIME,NETINTIME,ORIGHOLDTIME,QUEUETIME,RINGTIME,DISPIVECTOR,DISPSPLIT,FIRSTIVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,EQ_LOCID,ORIG_LOCID,ANS_LOCID,OBS_LOCID,UUI_LEN,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,CALL_DISP,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,UCID,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II,CWC1,CWC2,CWC3,CWC4,CWC5,VDN2,VDN3,VDN4,VDN5,VDN6,VDN7,VDN8,VDN9,ASAI_UUI,INTERRUPTDEL,AGENTSURPLUS,AGENTSKILLLEVEL,PREFSKILLLEVEL',
    format => 'V15 v12 x2 C17 A21 A16 A10' . 'A16 'x4 . 'A25 A25 A17 A17 A3' . 'A17 'x5 . 'A16 'x8 . 'A96 C4',
    bits => {index => 27, format => '@76b9'},
    signed => [16, 18, 19, 20],
    segment => 40,
    strstart => 53,
    strstop => 78
  },

  163 =>		# CMS R16.3 and above
  {
    length => 617,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTART_UTC,SEGSTOP,SEGSTOP_UTC,TALKTIME,NETINTIME,ORIGHOLDTIME,QUEUETIME,RINGTIME,DISPIVECTOR,DISPSPLIT,FIRSTIVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,EQ_LOCID,ORIG_LOCID,ANS_LOCID,OBS_LOCID,UUI_LEN,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,CALL_DISP,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,UCID,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II,CWC1,CWC2,CWC3,CWC4,CWC5,VDN2,VDN3,VDN4,VDN5,VDN6,VDN7,VDN8,VDN9,ASAI_UUI,INTERRUPTDEL,AGENTSURPLUS,AGENTSKILLLEVEL,PREFSKILLLEVEL,ICRRESENT,ICRPULLREASON',
    format => 'V15 v12 x2 C17 A21 A16 A10' . 'A16 'x4 . 'A25 A25 A17 A17 A3' . 'A17 'x5 . 'A16 'x8 . 'A96 C6',
    bits => {index => 27, format => '@76b9'},
    signed => [16, 18, 19, 20],
    segment => 40,
    strstart => 53,
    strstop => 78
  },

  170 =>		# CMS R17 and above
  {
    length => 629,
    header => 'CALLID,ACWTIME,ANSHOLDTIME,CONSULTTIME,DISPTIME,DURATION,SEGSTART,SEGSTART_UTC,SEGSTOP,SEGSTOP_UTC,TALKTIME,NETINTIME,ORIGHOLDTIME,QUEUETIME,RINGTIME,ORIG_ATTRIB_ID,ANS_ATTRIB_ID,OBS_ATTRIB_ID,DISPIVECTOR,DISPSPLIT,FIRSTIVECTOR,SPLIT1,SPLIT2,SPLIT3,TKGRP,EQ_LOCID,ORIG_LOCID,ANS_LOCID,OBS_LOCID,UUI_LEN,ASSIST,AUDIO,CONFERENCE,DA_QUEUED,HOLDABN,MALICIOUS,OBSERVINGCALL,TRANSFERRED,AGT_RELEASED,ACD,CALL_DISP,DISPPRIORITY,HELD,SEGMENT,ANSREASON,ORIGREASON,DISPSKLEVEL,EVENT1,EVENT2,EVENT3,EVENT4,EVENT5,EVENT6,EVENT7,EVENT8,EVENT9,UCID,DISPVDN,EQLOC,FIRSTVDN,ORIGLOGIN,ANSLOGIN,LASTOBSERVER,DIALED_NUM,CALLING_PTY,LASTDIGITS,LASTCWC,CALLING_II,CWC1,CWC2,CWC3,CWC4,CWC5,VDN2,VDN3,VDN4,VDN5,VDN6,VDN7,VDN8,VDN9,ASAI_UUI,INTERRUPTDEL,AGENTSURPLUS,AGENTSKILLLEVEL,PREFSKILLLEVEL,ICRRESENT,ICRPULLREASON',
    format => 'V18 v12 x2 C17 A21 A16 A10' . 'A16 'x4 . 'A25 A25 A17 A17 A3' . 'A17 'x5 . 'A16 'x8 . 'A96 C6',
    bits => {index => 30, format => '@76b9'},
    signed => [19, 21, 22, 23],
    segment => 43,
    strstart => 56,
    strstop => 81
  }
)
