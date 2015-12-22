#!/usr/bin/env perl

use strict;
use warnings;
use YAML qw/Dump LoadFile/;
use Getopt::Long;
use LWP::UserAgent;
use File::Temp qw/tempdir/;
use File::Spec::Functions; # catfile
use File::Path qw/make_path/;
use Time::HiRes qw/time/;
use IPC::Run qw/run timeout/;
use Log::Log4perl qw(:easy);
use POSIX qw/strftime/;
use JSON qw/encode_json/;

my %params;
GetOptions( \%params,
    'host=s',
    'username=s',
    'password=s',
    'mapping=s',
    'loglevel=s',
    'strip_width=i',
    'strip_offset=i',
    'image_height=i',
    'edge=i',
    'work_dir=s',
    'liter_per_cm=f',
    'output=s',
);

foreach( qw/host username password mapping/ ){
    if( not $params{$_} ){
        die( "Required parameter not defined: $_\n" );
    }
}

$params{loglevel}       ||= $INFO;
$params{edge}           ||= 20;
$params{strip_width}    ||= 60;
$params{image_height}   ||= 480;
$params{strip_offset}   ||= 236;
$params{liter_per_cm}   ||= 35.37; 

Log::Log4perl->easy_init( { level   => $params{loglevel} } );
my $logger = get_logger();
my $mapping = LoadFile( $params{mapping} ) or die( $! );

my $crop = sprintf( '%ux%u+%u+0', $params{strip_width}, $params{image_height}, $params{strip_offset} );

my $ua = LWP::UserAgent->new(
    keep_alive  => 1,
    );

if( $params{work_dir} and ! -d $params{work_dir} ){
    make_path( $params{work_dir} ) or die( $! );
}

my $work_dir = $params{work_dir} || tempdir( CLEANUP => 1 );

my $image_file = catfile( $work_dir, 'image.jpg' );
my $text_file = catfile( $work_dir, 'output.txt' );

DEBUG( sprintf "Saving image to: %s", $image_file );
DEBUG( sprintf "Output text to: %s", $text_file );

$ua->get( sprintf( 'http://%s/snapshot.cgi?user=%s&pwd=%s&%u',
            $params{host},
            $params{username},
            $params{password},
            time() ),
          ':content_file'   => $image_file,
          );

my @cmd = ( qw/convert -crop/, $crop, qw/-colorspace Gray -edge/, $params{edge}, qw/-liquid-rescale 1x100%/ );
push( @cmd, $image_file );
push( @cmd, $text_file );

my( $in, $out, $err );
run( \@cmd, \$in, \$out, \$err );
if( $err ){
    die( $err );
}

 # output edge detection image for visual confirmation
if( $logger->is_debug and $params{work_dir} ){
    my $edge_file = catfile( $params{work_dir}, 'edge.png' );
    DEBUG( "Writing edge image out to $edge_file" ); 
    @cmd = (  qw/convert -crop/, $crop, qw/-colorspace Gray -edge/, $params{edge}, $image_file, $edge_file );
    run( \@cmd, \$in, \$out, \$err );
    if( $err ){
        die( $err );
    }
}

open( my $fh_text, '<', $text_file ) or LOGDIE( $! );
my $header = readline( $fh_text );
my @pixels;
while( my $line = readline( $fh_text ) ){
    #0,0: ( 29, 29, 29)  #1D1D1D  gray(29,29,29)
    my( $pixel, $brightness ) = ( $line =~ m/^0\,(\d+): \(\s*(\d+),.*$/ );
    push( @pixels, $brightness );
}
close( $fh_text );

# Read until we find a value >100
my $start_search = undef;
my $level_pixel = undef;
foreach( 0 .. $#pixels ){
    if( not $start_search and $pixels[$_] > 100 ){
        $start_search = $_;
        DEBUG( "Starting search for line at pixel $start_search" );
    }
    if( $start_search and not $level_pixel and $pixels[$_] == 0 and $pixels[$_ + 1] == 0 and $pixels[$_ + 2 ] == 0 ){
        $level_pixel = $_;
        last;
    }
}
DEBUG( sprintf "Line is at %0.1f", $level_pixel );

my( $before, $after );
foreach( sort { $mapping->{$a} <=> $mapping->{$b} } keys( %{ $mapping } ) ){
    DEBUG( sprintf "Testing %u cm (%u pixel)", $_, $mapping->{$_} );
    if( not $before or ( $before and $mapping->{$_} < $level_pixel ) ){
        DEBUG( "Setting before: $_" );
        $before = $_;
    }
    if( not $after and $mapping->{$_} > $level_pixel ){
        DEBUG( "Setting after: $_" );
        $after = $_;
    }
}
DEBUG( sprintf "Before: %u cm | %u px", $before, $mapping->{$before} );
DEBUG( sprintf "After: %u cm | %u px", $after, $mapping->{$after} );

if( $params{work_dir} ){
    my $redline = catfile( $work_dir, 'red-line.png' );
    DEBUG( sprintf "Writing red-line image to %s", $redline );
    my( $in, $out, $err );
    my @cmd = qw/convert -fill red -draw/;
    push( @cmd, sprintf( 'line %i,%i %i,%i', $params{strip_offset}, $level_pixel, $params{strip_offset} + $params{strip_width}, $level_pixel ) );
    push( @cmd, $image_file );
    push( @cmd, $redline );
    run( \@cmd, \$in, \$out, \$err );
    if( $err ){
        ERROR( $err );
    }
}

my $fraction = 1 - ( ( $level_pixel - $mapping->{$after} ) / ( $mapping->{$before} - $mapping->{$after} ) );
DEBUG( sprintf "Fraction: %0.2f", $fraction );
my $level_cm = $before + ( ( $after - $before ) * $fraction );
my $level_liter = $level_cm * $params{liter_per_cm};
INFO( sprintf "Level cm: %0.2f", $level_cm );
INFO( sprintf "Level liter: %0.2f", $level_liter );

if( $params{output} ){
    my $time = time();
    my $microsecond = 1000 * ( $time - int( $time ) );
    my $document = {
        timestamp   => strftime( '%Y-%m-%dT%H:%M:%S.', gmtime( $time ) ) . sprintf( '%03uZ', $microsecond ),
        level_cm    => 0 + sprintf( '%0.1f', $level_cm ),
        level_liter => 0 + sprintf( '%0.1f', $level_liter ),
        level_pixel => $level_pixel,
    };

    DEBUG( sprintf "Writing output to log file: %s", $params{output} );
    open( my $fh_output, '>>', $params{output} ) or die( $! );
    print $fh_output encode_json( $document ) . "\n";
    close $fh_output;

    if( $params{work_dir} ){
        open( my $fh_last, '>', catfile( $params{work_dir}, 'document.json' ) ) or die( $! );
        printf $fh_last JSON->new->utf8->pretty->encode( $document ) . "\n";
        close $fh_last;
    }
}


exit( 0 );

=head1 NAME

oil-tank-level.pl - Determine oil tank level from webcam

=head1 SYNOPSIS



=head1 DESCRIPTION



=head1 OPTIONS

=over 4

=item --option

option description


=back

=head1 COPYRIGHT

Copyright 2015, Robin Clarke

=head1 AUTHOR

Robin Clarke C<perl@robinclarke.net>

=cut

