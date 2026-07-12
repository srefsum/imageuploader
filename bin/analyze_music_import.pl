#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Basename qw(basename);
use Encode qw(decode encode);
use FindBin;

# Compare one or more source folders (artist or album) against the LMS music library.
# Usage:
#   ./bin/analyze_music_import.pl /path/to/ArtistA [/path/to/ArtistB ...]
#   ./bin/analyze_music_import.pl --library /srv/music /path/to/source

my $library_root = '/srv/music';
my @sources;

while (@ARGV) {
    my $arg = shift @ARGV;
    if ( $arg eq '--library' ) {
        $library_root = shift @ARGV // die "--library requires a path\n";
    }
    else {
        push @sources, $arg;
    }
}

die "Usage: $0 [--library /srv/music] /path/to/source-folder [...]\n" unless @sources;
die "Library root not found: $library_root\n" unless -d $library_root;

binmode STDOUT, ':encoding(UTF-8)';

my %library_artists = map { decode_name($_) => 1 } list_dir_names($library_root);

print "Music import analysis\n";
print "=====================\n";
print "Library: $library_root\n";
print "Artists in library: ", scalar keys %library_artists, "\n\n";

for my $source (@sources) {
    die "Source not found: $source\n" unless -d $source;
    analyze_source( $source, \%library_artists );
    print "\n";
}

sub analyze_source {
    my ( $source, $artists ) = @_;
    my $source_name = decode_name( basename($source) );

    print "Source: $source\n";
    print "Folder name: $source_name\n";

    my @children = list_dirs($source);
    my @files    = list_files($source);
    my $mode     = classify_source( \@children, \@files );

    print "Detected mode: $mode\n";

    if ( $mode eq 'artist' ) {
        analyze_artist_source( $source, $source_name, $artists );
    }
    elsif ( $mode eq 'album' ) {
        analyze_album_source( $source, $source_name, $artists, undef );
    }
    else {
        print "WARNING: Ambiguous layout — treat as album-only or inspect manually.\n";
        analyze_album_source( $source, $source_name, $artists, undef );
    }
}

sub classify_source {
    my ( $dirs, $files ) = @_;

    return 'empty' if !@$dirs && !@$files;

    my $audio_in_root = grep { is_audio($_) } @$files;
    return 'album' if $audio_in_root;

    my $all_dirs_look_like_albums = 1;
    for my $dir (@$dirs) {
        my $has_audio = 0;
        my $has_subdirs = 0;
        for my $child ( list_all($dir) ) {
            $has_audio   = 1 if -f $child && is_audio( ( File::Spec->splitpath($child) )[2] );
            $has_subdirs = 1 if -d $child;
        }
        if ( $has_subdirs && !$has_audio ) {
            $all_dirs_look_like_albums = 0;
        }
    }

    return 'artist' if @{$dirs} && !$audio_in_root && $all_dirs_look_like_albums;
    return 'album';
}

sub analyze_artist_source {
    my ( $source, $artist_name, $artists ) = @_;
    my $artist_exists = $artists->{$artist_name};

    print "Artist in library: ", ( $artist_exists ? 'YES (merge only)' : 'NO (new artist)' ), "\n";

    my $artist_target = File::Spec->catdir( $library_root, $artist_name );
    my @albums        = list_dirs($source);

    print "Albums in source: ", scalar @albums, "\n";

    my ( $new_albums, $existing_albums, $new_files, $existing_files, $other_files ) =
      ( 0, 0, 0, 0, 0 );

    for my $album_dir (@albums) {
        my $album_name = decode_name( basename($album_dir) );
        my $album_target = File::Spec->catdir( $artist_target, $album_name );
        my $album_exists = -d $album_target;

        $album_exists ? $existing_albums++ : $new_albums++;

        for my $file ( list_files_recursive($album_dir) ) {
            my $rel      = File::Spec->abs2rel( $file, $album_dir );
            my $target   = File::Spec->catfile( $album_target, split m{[/\\]}, $rel );
            my $basename = decode_name( ( File::Spec->splitpath($file) )[2] );

            if ( -e $target ) {
                $existing_files++;
            }
            elsif ( is_uploadable($basename) ) {
                $new_files++;
            }
            else {
                $other_files++;
            }
        }
    }

    print "\nSummary for artist import:\n";
    print "  New albums to create:      $new_albums\n";
    print "  Existing albums (merge):   $existing_albums\n";
    print "  New files to upload:       $new_files\n";
    print "  Files already on server:   $existing_files (will be skipped)\n";
    print "  Other/skipped file types:  $other_files\n";
    print "  Folders overwritten:       0 (policy: never)\n";
    print "  Files overwritten:         0 (policy: never)\n";

    print "\nAlbum detail:\n";
    for my $album_dir (@albums) {
        my $album_name = decode_name( basename($album_dir) );
        my @tracks = grep { is_audio($_) } map { decode_name( ( File::Spec->splitpath($_) )[2] ) } list_files_recursive($album_dir);
        my @images = grep { is_image($_) } map { decode_name( ( File::Spec->splitpath($_) )[2] ) } list_files_recursive($album_dir);
        my $status = -d File::Spec->catdir( $artist_target, $album_name ) ? 'exists' : 'new';
        printf "  - %-40s [%s] %d tracks, %d images\n", $album_name, $status, scalar @tracks, scalar @images;
    }
}

sub analyze_album_source {
    my ( $source, $album_name, $artists, $artist_name ) = @_;

    if ( !defined $artist_name ) {
        print "Album-only source — artist must be chosen at upload time.\n";
        print "Matching artists in library (by album name under artist):\n";
        my @matches;
        for my $artist ( sort keys %$artists ) {
            next unless -d File::Spec->catdir( $library_root, $artist, $album_name );
            push @matches, $artist;
        }
        if (@matches) {
            print "  Possible matches: ", join( ', ', @matches ), "\n";
            $artist_name = $matches[0] if @matches == 1;
        }
        else {
            print "  No exact album name match found — import would create a new artist unless selected.\n";
        }
    }

    my $artist_target = defined $artist_name ? File::Spec->catdir( $library_root, $artist_name ) : undef;
    my $album_target  = $artist_target ? File::Spec->catdir( $artist_target, $album_name ) : "(artist TBD)/$album_name";

    print "Target album path: $album_target\n";
    print "Album folder exists: ", ( -d $album_target ? 'YES' : 'NO' ), "\n";

    my ( $new_files, $existing_files, $other_files ) = ( 0, 0, 0 );
    for my $file ( list_files_recursive($source) ) {
        my $rel    = File::Spec->abs2rel( $file, $source );
        my $target = File::Spec->catfile( $album_target, split m{[/\\]}, $rel );
        my $base   = decode_name( ( File::Spec->splitpath($file) )[2] );

        if ( $album_target =~ /^\(/ ) {
            $new_files++ if is_uploadable($base);
            next;
        }

        if ( -e $target ) { $existing_files++ }
        elsif ( is_uploadable($base) ) { $new_files++ }
        else { $other_files++ }
    }

    my @tracks = grep { is_audio($_) } map { decode_name( ( File::Spec->splitpath($_) )[2] ) } list_files_recursive($source);
    my @images = grep { is_image($_) } map { decode_name( ( File::Spec->splitpath($_) )[2] ) } list_files_recursive($source);

    print "\nSummary for album import:\n";
    print "  Tracks in source:          ", scalar @tracks, "\n";
    print "  Images in source:          ", scalar @images, "\n";
    print "  New files to upload:       $new_files\n";
    print "  Files already on server:   $existing_files (will be skipped)\n";
    print "  Other/skipped file types:  $other_files\n";
}

sub list_dir_names {
    my ($path) = @_;
    opendir my $dh, $path or return ();
    my @dirs = sort grep { $_ ne '.' && $_ ne '..' && -d File::Spec->catdir( $path, $_ ) } readdir($dh);
    closedir $dh;
    return @dirs;
}

sub list_dirs {
    my ($path) = @_;
    return map { File::Spec->catdir( $path, $_ ) } list_dir_names($path);
}

sub list_files {
    my ($path) = @_;
    opendir my $dh, $path or return ();
    my @files = sort grep { $_ ne '.' && $_ ne '..' && -f File::Spec->catfile( $path, $_ ) } readdir($dh);
    closedir $dh;
    return map { File::Spec->catfile( $path, $_ ) } @files;
}

sub list_all {
    my ($path) = @_;
    return ( list_dirs($path), list_files($path) );
}

sub list_files_recursive {
    my ( $path, @found ) = @_;
    for my $entry ( list_all($path) ) {
        if ( -d $entry ) {
            @found = list_files_recursive( $entry, @found );
        }
        else {
            push @found, $entry;
        }
    }
    return @found;
}

sub ext {
    my ($name) = @_;
    return lc( ( $name =~ /\.([^.]+)$/ ) ? $1 : '' );
}

sub is_audio {
    my ($name) = @_;
    return ext($name) =~ /^(?:mp3|flac|ogg|m4a|aac|wma|wav)$/;
}

sub is_image {
    my ($name) = @_;
    return ext($name) =~ /^(?:jpg|jpeg|png|gif|webp)$/;
}

sub is_uploadable {
    my ($name) = @_;
    return is_audio($name) || is_image($name);
}

sub decode_name {
    my ($name) = @_;
    return '' if !defined $name;
    return $name if utf8::is_utf8($name);
    return decode( 'UTF-8', $name );
}
