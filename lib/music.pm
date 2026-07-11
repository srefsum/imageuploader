package music;
use strict;
use warnings;

use File::Basename;
use File::Spec;
use File::MimeInfo;
use Cwd qw(abs_path);
use URI::Escape qw(uri_escape_utf8);
use Encode qw(decode encode);
use JSON::PP qw(encode_json decode_json);
use HTTP::Tiny;

sub music_root {
    return $main::config->{music_library_path} // '/srv/music';
}

sub allowed_extensions {
    my $ext_cfg = $main::config->{music_extensions} // 'mp3 flac ogg m4a aac wma wav';
    my @ext = ref $ext_cfg eq 'ARRAY' ? @$ext_cfg : split /\s+/, $ext_cfg;
    return map { lc($_) } grep { $_ ne '' } @ext;
}

sub allowed_image_extensions {
    my $ext_cfg = $main::config->{music_image_extensions} // 'jpg jpeg png gif webp';
    my @ext = ref $ext_cfg eq 'ARRAY' ? @$ext_cfg : split /\s+/, $ext_cfg;
    return map { lc($_) } grep { $_ ne '' } @ext;
}

sub file_extension {
    my ($name) = @_;
    return lc( ( $name =~ /\.([^.]+)$/ ) ? $1 : '' );
}

sub is_audio_file {
    my $name = shift;
    my %allowed = map { $_ => 1 } allowed_extensions();
    return $allowed{ file_extension($name) };
}

sub is_image_file {
    my $name = shift;
    my %allowed = map { $_ => 1 } allowed_image_extensions();
    return $allowed{ file_extension($name) };
}

sub is_uploadable_file {
    my $name = shift;
    return is_audio_file($name) || is_image_file($name);
}

sub path_depth {
    my ($rel_path) = @_;
    return 0 if !defined($rel_path) || $rel_path eq '';
    my @parts = grep { $_ ne '' } split m{/}, $rel_path;
    return scalar @parts;
}

sub can_create_subdir {
    my ($rel_path) = @_;
    my $depth = path_depth($rel_path);
    return $depth <= 2;
}

sub can_upload {
    my ($rel_path) = @_;
    return path_depth($rel_path) >= 2;
}

sub create_subdir_label {
    my ($rel_path) = @_;
    my $depth = path_depth($rel_path);
    return 'artist'  if $depth == 0;
    return 'album'   if $depth == 1;
    return 'CD/disc' if $depth == 2;
    return 'folder';
}

sub validate_dirname {
    my ($name) = @_;
    return 0 if !defined($name) || $name eq '' || $name eq '.' || $name eq '..';
    return 0 if $name =~ m{[/\\]};
    return 0 if $name =~ /\.\./;
    return 1;
}

sub sanitize_dirname {
    my ($name) = @_;
    $name =~ s/^\s+|\s+$//g;
    $name =~ s/[\x00-\x1f]//g;
    return $name;
}

sub create_subdir {
    my ( $parent_path, $new_dir ) = @_;

    $parent_path = normalize_music_path($parent_path // '');
    $new_dir     = sanitize_dirname( normalize_text( $new_dir // '' ) );

    return 0 unless validate_dirname($new_dir);
    return 0 unless can_create_subdir($parent_path);

    my $parent_abs = resolve_music_path($parent_path);
    return 0 unless defined $parent_abs && -d $parent_abs;

    my $new_abs = File::Spec->catdir( $parent_abs, $new_dir );
    return 0 if -e $new_abs;

    return mkdir($new_abs) ? 1 : 0;
}

sub upload_accept_list {
    my ($rel_path) = @_;
    my @ext = allowed_extensions();
    if ( can_upload($rel_path) ) {
        push @ext, allowed_image_extensions();
    }
    my %seen;
    @ext = grep { !$seen{lc($_)}++ } @ext;
    return @ext;
}

sub normalize_text {
    my ($s) = @_;
    return '' if !defined $s;
    return $s if utf8::is_utf8($s);
    return decode( 'UTF-8', $s );
}

sub html_escape_text {
    my ( $q, $text ) = @_;
    return '' if !defined $text || $text eq '';
    # CGI::escapeHTML downgrades UTF-8-flagged strings to Latin-1; pass bytes instead.
    my $bytes = utf8::is_utf8($text) ? encode( 'UTF-8', $text ) : $text;
    return $q->escapeHTML($bytes);
}

sub html_escape_display {
    my ( $q, $text ) = @_;
    return html_escape_text( $q, normalize_text($text) );
}

sub normalize_music_path {
    my ($path) = @_;
    return join_path_parts( split_path_parts($path) );
}

sub split_path_parts {
    my ($path) = @_;
    return () if !defined($path) || $path eq '';
    $path =~ s/^\/+|\/+$//g;
    return map { normalize_text($_) } grep { $_ ne '' } split m{/}, $path;
}

sub join_path_parts {
    my (@parts) = @_;
    return join '/', grep { defined && $_ ne '' } @parts;
}

sub extend_path {
    my ( $rel_path, @extra ) = @_;
    return join_path_parts( split_path_parts($rel_path), map { normalize_text($_) } @extra );
}

sub encode_path_parts {
    my (@parts) = @_;
    return join '/', map { uri_escape_utf8($_) } @parts;
}

sub encode_path_param {
    my ($path) = @_;
    return '' if !defined($path) || $path eq '';
    return encode_path_parts( split_path_parts($path) );
}

sub resolve_music_path {
    my ($rel_path) = @_;

    $rel_path = normalize_music_path($rel_path);

    my $root = music_root();
    return abs_path($root) if $rel_path eq '';

    return undef if $rel_path =~ /\.\./;

    my $abs = $root;
    for my $part ( split m{/}, $rel_path ) {
        next if $part eq '' || $part eq '.';
        return undef if $part eq '..';
        $abs = File::Spec->catdir( $abs, $part );
    }

    return undef unless -e $abs;

    my $root_abs   = abs_path($root);
    my $target_abs = abs_path($abs) // $abs;
    return undef unless defined $root_abs;
    return undef unless index( $target_abs, $root_abs ) == 0;

    return $target_abs;
}

sub list_level {
    my ($abs_path) = @_;
    my @dirs;
    my @tracks;
    my @other;

    opendir( my $dh, $abs_path ) or return ( [], [], [] );
    my @entries = readdir($dh);
    closedir($dh);

    for my $entry (@entries) {
        next if $entry eq '.' || $entry eq '..';
        my $full = File::Spec->catfile( $abs_path, $entry );
        if ( -d $full ) {
            push @dirs, $entry;
        } elsif ( -f $full && is_audio_file($entry) ) {
            push @tracks, $entry;
        } elsif ( -f $full ) {
            push @other, $entry;
        }
    }

    return ( [ sort @dirs ], [ sort @tracks ], [ sort @other ] );
}

sub format_size {
    my ($bytes) = @_;
    return '0 B' unless defined $bytes && $bytes >= 0;
    if ( $bytes >= 1024 * 1024 ) {
        return sprintf( '%.1f MB', $bytes / ( 1024 * 1024 ) );
    }
    if ( $bytes >= 1024 ) {
        return sprintf( '%.1f KB', $bytes / 1024 );
    }
    return "$bytes B";
}

sub build_breadcrumb {
    my ( $q, $rel_path ) = @_;

    my $html = qq{<a href="/index">Home</a> / <a href="/music">Music Library</a>};
    return $html if !defined($rel_path) || $rel_path eq '';

    my @accum;
    for my $part ( split_path_parts($rel_path) ) {
        push @accum, $part;
        my $enc = encode_path_parts(@accum);
        $html .= ' / <a href="/music/browse?path=' . $enc . '">' . html_escape_text( $q, $part ) . '</a>';
    }

    return $html;
}

sub page_title_for_path {
    my ($rel_path) = @_;
    if ( !defined($rel_path) || $rel_path eq '' ) {
        return 'Music Library';
    }
    my @parts = split_path_parts($rel_path);
    return @parts ? $parts[-1] : 'Music Library';
}

sub trigger_lms_rescan {
    my ( $host_ip, $port ) = @_;
    return 0 unless defined $host_ip && $host_ip ne '';

    my $http = HTTP::Tiny->new( timeout => 30 );
    my $body = encode_json(
        {
            id     => 1,
            method => 'slim.request',
            params => [ '', ['rescan'] ],
        }
    );

    my $response = $http->post(
        "http://$host_ip:$port/jsonrpc.js",
        {
            headers => { 'Content-Type' => 'application/json' },
            content => $body,
        }
    );

    return $response->{success} ? 1 : 0;
}

sub browse {
    my ( $resp, $q, $rel_path ) = @_;

    $rel_path = normalize_music_path( $rel_path // '' );

    my $abs = resolve_music_path($rel_path);
    unless ( defined $abs && -d $abs ) {
        main::print_error_page( $resp, 'The requested music folder is not available.' );
        return;
    }

    my ( $dirs, $tracks, $other ) = list_level($abs);
    my @base_parts = split_path_parts($rel_path);
    my $enc_path   = encode_path_parts(@base_parts);
    my $depth      = path_depth($rel_path);

    my $upload_section = '';
    if ( can_upload($rel_path) ) {
        $upload_section = qq{<div class="btn-group"><a href="/music/upload?path=$enc_path" class="btn btn-primary">Upload music or images</a></div>\n};
    }

    my $flash_message = '';
    if ( defined $resp->{Params}{flash} ) {
        if ( $resp->{Params}{flash} eq 'dir_created' ) {
            $flash_message = '<div class="alert alert-success">Folder created successfully.</div>';
        } elsif ( $resp->{Params}{flash} eq 'dir_failed' ) {
            $flash_message = '<div class="alert alert-error">Could not create folder. Check the name and try again.</div>';
        }
    }

    my $album_art = '';
    if ( opendir( my $art_dh, $abs ) ) {
        my @art_files = grep { lc($_) eq 'folder.jpg' } readdir($art_dh);
        closedir($art_dh);
        if (@art_files) {
            my $art_file  = $art_files[0];
            my $art_path  = extend_path( $rel_path, $art_file );
            my $art_enc   = encode_path_param($art_path);
            $album_art = qq{<div class="card music-album-art"><img class="gallery-thumb" src="/music/serve?path=$art_enc" alt="Album art" /></div>\n};
        }
    }

    my $folder_section = '';
    my $folder_heading = $depth == 0 ? 'Artists' : ( $depth == 1 ? 'Albums' : 'Disc folders' );
    if (@$dirs) {
        $folder_section = "<div class=\"section\"><h2>$folder_heading</h2>\n<div class=\"folder-list\">\n";
        for my $dir (@$dirs) {
            my $child = extend_path( $rel_path, $dir );
            my $enc   = encode_path_param($child);
            my $label = html_escape_display( $q, $dir );
            $folder_section .= qq{  <div class="folder-item"><div class="folder-item-actions"><a href="/music/browse?path=$enc">&#128193; $label</a>};
            if ( can_upload($child) ) {
                $folder_section .= qq{<a href="/music/upload?path=$enc" class="btn btn-secondary">Upload</a>};
            }
            $folder_section .= "</div></div>\n";
        }
        $folder_section .= "</div></div>\n";
    }

    my $track_section = '';
    if (@$tracks) {
        $track_section = "<div class=\"section\"><h2>Tracks</h2>\n";
        $track_section .= "<div class=\"card\"><label class=\"form-label\" for=\"track-filter\">Filter by filename</label>\n";
        $track_section .= "<input class=\"form-input gallery-filter\" type=\"text\" id=\"track-filter\" placeholder=\"Search tracks...\" /></div>\n";
        $track_section .= "<ul class=\"track-list\">\n";
        for my $track (@$tracks) {
            my $file_path = extend_path( $rel_path, $track );
            my $enc       = encode_path_param($file_path);
            my $label       = html_escape_display( $q, $track );
            my $filter_name = encode( 'UTF-8', lc( normalize_text($track) ) );
            my $size      = format_size( -s File::Spec->catfile( $abs, $track ) );
            $track_section .= qq{  <li class="track-item" data-name="$filter_name"><a href="/music/serve?path=$enc">$label</a><span class="track-meta">$size</span></li>\n};
        }
        $track_section .= "</ul></div>\n";
    } elsif ( !@$dirs ) {
        $track_section = '<p class="empty-state">No folders or audio files in this directory.</p>';
    }

    my $other_section = '';
    if (@$other) {
        $other_section = "<div class=\"section\"><h2>Other files</h2>\n<ul class=\"track-list\">\n";
        for my $file (@$other) {
            my $file_path = extend_path( $rel_path, $file );
            my $enc       = encode_path_param($file_path);
            my $label = html_escape_display( $q, $file );
            $other_section .= qq{  <li class="track-item" data-name="} . encode( 'UTF-8', lc( normalize_text($file) ) ) . qq{"><a href="/music/serve?path=$enc">$label</a></li>\n};
        }
        $other_section .= "</ul></div>\n";
    }

    my $create_dir_form = '';
    if ( can_create_subdir($rel_path) ) {
        my $label       = create_subdir_label($rel_path);
        my $parent_enc  = html_escape_text( $q, $rel_path );
        my $placeholder = $depth == 0 ? 'New Artist Name' : ( $depth == 1 ? 'New Album Name' : 'CD 1' );
        $create_dir_form = <<"HTML";
<div class="card">
    <h2>Create new $label folder</h2>
    <form action="/music/create" method="post">
        <input type="hidden" name="parent_path" value="$parent_enc">
        <div class="form-group">
            <label class="form-label" for="new_dir">Folder name</label>
            <input class="form-input" type="text" id="new_dir" name="new_dir" placeholder="$placeholder" required>
        </div>
        <button type="submit" class="btn btn-primary">Create folder</button>
    </form>
</div>
HTML
    }

    $resp->{variables}{page_title}       = html_escape_text( $q, page_title_for_path($rel_path) );
    $resp->{variables}{breadcrumb}         = build_breadcrumb( $q, $rel_path );
    $resp->{variables}{flash_message}      = $flash_message;
    $resp->{variables}{upload_section}     = $upload_section;
    $resp->{variables}{album_art}          = $album_art;
    $resp->{variables}{folder_section}     = $folder_section;
    $resp->{variables}{track_section}      = $track_section;
    $resp->{variables}{other_section}      = $other_section;
    $resp->{variables}{create_dir_form}    = $create_dir_form;

    main::render_page(
        $resp,
        content_template => '../templates/music_browse.html',
        title            => page_title_for_path($rel_path),
        active_page      => 'music',
    );
}

sub show_upload_form {
    my ( $resp, $q, $rel_path ) = @_;

    $rel_path = normalize_music_path( $rel_path // '' );

    my $abs = resolve_music_path($rel_path);
    unless ( defined $abs && -d $abs ) {
        main::print_error_page( $resp, 'The selected upload folder is not available.' );
        return;
    }

    unless ( can_upload($rel_path) ) {
        main::print_error_page( $resp, 'Upload is only available at album level and below.' );
        return;
    }

    my $max_mb   = $main::config->{music_upload_max_mb} // 100;
    my @ext      = upload_accept_list($rel_path);
    my $accept   = join( ',', map { ".$_" } @ext );
    my $ext_text = join( ', ', map { ".$_" } @ext );

    my $display_path = $rel_path eq '' ? '(library root)' : $rel_path;

    $resp->{variables}{upload_path}         = html_escape_text( $q, $rel_path );
    $resp->{variables}{upload_path_display} = html_escape_text( $q, $display_path );
    $resp->{variables}{accept_extensions}   = $accept;
    $resp->{variables}{extensions_text}     = $ext_text;
    $resp->{variables}{max_upload_mb}       = $max_mb;

    main::render_page(
        $resp,
        content_template => '../templates/music_upload.html',
        title            => 'Upload Music or Images',
        active_page      => 'music',
    );
}

sub upload {
    my ( $resp, $q ) = @_;

    my $rel_path = normalize_music_path( scalar $q->param('path') );

    my $abs = resolve_music_path($rel_path);
    unless ( defined $abs && -d $abs ) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = 'The selected upload folder is not available.';
        return;
    }

    unless ( can_upload($rel_path) ) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = 'Upload is only available at album level and below.';
        return;
    }

    my $file_param        = $q->param('filename') // '';
    my $upload_filehandle = $q->upload('filename');
    my $max_mb            = $main::config->{music_upload_max_mb} // 100;

    if ( !$upload_filehandle ) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = "No file received or file size exceeds the ${max_mb} MB limit.";
        return;
    }

    my $safe_filename = basename($file_param);
    if ( $safe_filename =~ /[^A-Za-z0-9._\- \x{80}-\x{FFFF}]/ ) {
        $safe_filename =~ s/[^A-Za-z0-9._\- \x{80}-\x{FFFF}]//g;
    }

    if ( $safe_filename eq '' || !is_uploadable_file($safe_filename) ) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = 'Invalid or unsupported file type. Upload audio or image files only.';
        return;
    }

    my $final_path = File::Spec->catfile( $abs, $safe_filename );

    open( my $out_fh, '>', $final_path ) or do {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = "Could not write file: $!";
        return;
    };
    binmode $out_fh;

    my $buffer;
    while ( read( $upload_filehandle, $buffer, 16384 ) ) {
        print $out_fh $buffer;
    }
    close $out_fh;

    my $dest_label = $rel_path eq '' ? 'Music Library' : $rel_path;
    $resp->{variables}{result_type}      = 'success';
    $resp->{variables}{result_message}   = "File <strong>" . html_escape_display( $q, $safe_filename ) . "</strong> was uploaded to <strong>" . html_escape_text( $q, $dest_label ) . "</strong>.";
    $resp->{variables}{music_path}       = $rel_path;

    my $rescan_cfg = lc( $main::config->{music_rescan_after_upload} // 'Yes' );
    if ( $rescan_cfg eq 'yes' ) {
        my $host_ip = main::getHostIPAdress();
        my $port    = $main::config->{music_server_port} // 9000;
        if ( trigger_lms_rescan( $host_ip, $port ) ) {
            $resp->{variables}{rescan_note} = 'LMS library rescan was triggered.';
        } else {
            $resp->{variables}{rescan_note} = 'Upload succeeded, but LMS rescan could not be triggered.';
        }
    }
}

sub serve {
    my ( $resp, $q ) = @_;

    my $rel_path = normalize_music_path( $resp->{Params}{path} // '' );

    my $abs = resolve_music_path($rel_path);
    unless ( defined $abs && -f $abs ) {
        print $q->header( -status => '404 Not Found' );
        print "File not found.";
        return;
    }

    my $mime = mimetype($abs) || 'application/octet-stream';

    open( my $fh, '<:raw', $abs ) or die "Cannot open: $!";
    print $q->header(
        -type           => $mime,
        -content_length => -s $abs,
        -expires        => '+1d',
    );

    while ( read( $fh, my $buffer, 10240 ) ) {
        print $buffer;
    }
    close($fh);
}

1;
