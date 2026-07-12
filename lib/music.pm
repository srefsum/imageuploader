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

sub allow_overwrite {
    my $value = lc( $main::config->{music_overwrite} // 'No' );
    return $value eq 'yes';
}

sub import_skip_patterns {
    my $cfg = $main::config->{music_import_skip_files} // 'desktop.ini Thumbs.db .DS_Store *.m3u';
    my @patterns = ref $cfg eq 'ARRAY' ? @$cfg : split /\s+/, $cfg;
    return grep { $_ ne '' } @patterns;
}

sub is_skipped_import_file {
    my ($name) = @_;
    my $base = lc( basename($name) );
    for my $pattern ( import_skip_patterns() ) {
        my $lc = lc($pattern);
        if ( $lc =~ /^\*\.(.+)$/ ) {
            return 1 if $base =~ /\.\Q$1\E$/i;
        }
        elsif ( $base eq $lc ) {
            return 1;
        }
    }
    return 0;
}

sub sanitize_filename {
    my ($name) = @_;
    $name = basename( normalize_text($name) );
    if ( $name =~ /[^A-Za-z0-9._\- \x{80}-\x{FFFF}]/ ) {
        $name =~ s/[^A-Za-z0-9._\- \x{80}-\x{FFFF}]//g;
    }
    return $name;
}

sub validate_path_parts {
    my (@parts) = @_;
    return 0 if !@parts;
    for my $part (@parts) {
        return 0 unless validate_dirname($part);
    }
    return 1;
}

sub abs_path_for_rel {
    my ($rel_path) = @_;

    $rel_path = normalize_music_path($rel_path);

    my $root = music_root();
    return abs_path($root) if $rel_path eq '';

    return undef if $rel_path =~ /\.\./;

    my $abs = $root;
    for my $part ( split m{/}, $rel_path ) {
        next if $part eq '' || $part eq '.';
        return undef if $part eq '..';
        return undef unless validate_dirname($part);
        $abs = File::Spec->catdir( $abs, $part );
    }

    my $root_abs = abs_path($root);
    return undef unless defined $root_abs;

    my $target_abs = abs_path($abs) // $abs;
    return undef unless index( $target_abs, $root_abs ) == 0;

    return $target_abs;
}

sub ensure_parent_dirs {
    my ($abs_file) = @_;

    my $root_abs = abs_path( music_root() );
    return 0 unless defined $root_abs;

    my $parent = dirname($abs_file);
    return 0 unless index( $parent, $root_abs ) == 0;

    my @to_create;
    my $current = $parent;
    while ( index( $current, $root_abs ) == 0 && $current ne $root_abs ) {
        push @to_create, $current unless -d $current;
        my $next = dirname($current);
        last if $next eq $current;
        $current = $next;
    }

    for my $dir ( reverse @to_create ) {
        return 0 if -e $dir && !-d $dir;
        mkdir($dir) or return 0;
    }

    return 1;
}

sub safe_write_file {
    my ( $abs_path, $upload_fh ) = @_;

    if ( -d $abs_path ) {
        return ( status => 'skipped', reason => 'is_directory' );
    }

    if ( -e $abs_path ) {
        if ( !allow_overwrite() ) {
            return ( status => 'skipped', reason => 'exists' );
        }
    }

    return ( status => 'error', reason => 'mkdir_failed' ) unless ensure_parent_dirs($abs_path);

    my $existed = -e $abs_path;
    open( my $out_fh, '>', $abs_path ) or return ( status => 'error', reason => "write_failed:$!" );
    binmode $out_fh;

    my $buffer;
    while ( read( $upload_fh, $buffer, 16384 ) ) {
        print $out_fh $buffer;
    }
    close $out_fh;

    my $status = ( $existed && allow_overwrite() ) ? 'overwritten' : 'created';
    return ( status => $status );
}

sub list_artists {
    my $root = music_root();
    opendir my $dh, $root or return ();
    my @artists = sort grep { $_ ne '.' && $_ ne '..' && -d File::Spec->catdir( $root, $_ ) } readdir($dh);
    closedir $dh;
    return map { normalize_text($_) } @artists;
}

sub upload_file_entries {
    my ($q) = @_;
    my @entries;
    my @names = $q->param('filename');
    @names = grep { defined && $_ ne '' } @names;

    if (@names) {
        for my $name (@names) {
            my $fh = $q->upload($name);
            push @entries, { name => $name, fh => $fh } if $fh;
        }
        return @entries if @entries;
    }

    my $fh = $q->upload('filename');
    if ($fh) {
        push @entries,
          {
            name => scalar( $q->param('filename') // 'upload.bin' ),
            fh   => $fh,
          };
    }

    return @entries;
}

sub map_import_destination {
    my ( $mode, $source_artist, $source_album, $target_artist, $relpath ) = @_;

    $relpath =~ s{\\}{/}g;
    $relpath =~ s{^/+|/+$}{}g;

    my @parts = split_path_parts($relpath);
    return '' if !@parts;

    if ( $mode eq 'artist' ) {
        return join_path_parts( $source_artist, @parts );
    }

    return join_path_parts( $target_artist, $source_album, @parts );
}

sub apply_upload_summary {
    my ( $resp, $q, $summary ) = @_;

    my $created   = $summary->{created}   // [];
    my $skipped   = $summary->{skipped}   // [];
    my $rejected  = $summary->{rejected}  // [];
    my $errors    = $summary->{errors}    // [];
    my $rel_path  = $summary->{dest_path} // '';
    my $dest_label = $rel_path eq '' ? 'Music Library' : $rel_path;

    my $created_count  = scalar @$created;
    my $skipped_count  = scalar @$skipped;
    my $rejected_count = scalar @$rejected;
    my $error_count    = scalar @$errors;

    if ( $created_count == 0 && $error_count > 0 && $skipped_count == 0 && $rejected_count == 0 ) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = html_escape_text( $q, $errors->[0]{message} );
        return;
    }

    my $type = ( $created_count > 0 || $skipped_count > 0 ) ? 'success' : 'error';
    $resp->{variables}{result_type} = $type;

    my $message = "Uploaded <strong>$created_count</strong> file(s) to <strong>"
      . html_escape_text( $q, $dest_label ) . '</strong>.';
    if ( $skipped_count > 0 ) {
        $message .= " Skipped <strong>$skipped_count</strong> existing file(s).";
    }
    if ( $rejected_count > 0 ) {
        $message .= " Rejected <strong>$rejected_count</strong> unsupported file(s).";
    }
    if ( $error_count > 0 ) {
        $message .= " <strong>$error_count</strong> error(s) occurred.";
    }

    $resp->{variables}{result_message} = $message;
    $resp->{variables}{music_path}     = $rel_path;
    $resp->{variables}{detail_lists}   = build_upload_detail_html( $q, $summary );

    if ( $created_count > 0 ) {
        maybe_trigger_rescan($resp);
    }
}

sub build_upload_detail_html {
    my ( $q, $summary ) = @_;

    my $html = '';
    for my $section (
        [ 'Created', $summary->{created}  // [], 'created' ],
        [ 'Skipped (already on server)', $summary->{skipped}  // [], 'skipped' ],
        [ 'Rejected', $summary->{rejected} // [], 'rejected' ],
        [ 'Errors', $summary->{errors}   // [], 'error' ],
    ) {
        my ( $title, $items, $class ) = @$section;
        next if !@$items;

        $html .= qq{<div class="card import-detail"><h3>$title</h3><ul class="track-list">\n};
        for my $item (@$items) {
            my $label = ref $item eq 'HASH' ? ( $item->{path} // $item->{message} ) : $item;
            $html .= qq{  <li class="track-item import-item import-item--$class">}
              . html_escape_text( $q, $label ) . "</li>\n";
        }
        $html .= "</ul></div>\n";
    }

    return $html;
}

sub maybe_trigger_rescan {
    my ($resp) = @_;

    my $rescan_cfg = lc( $main::config->{music_rescan_after_upload} // 'Yes' );
    return if $rescan_cfg ne 'yes';

    my $host_ip = main::getHostIPAdress();
    my $port    = $main::config->{music_server_port} // 9000;
    if ( trigger_lms_rescan( $host_ip, $port ) ) {
        $resp->{variables}{rescan_note} = 'LMS library rescan was triggered.';
    } else {
        $resp->{variables}{rescan_note} = 'Upload succeeded, but LMS rescan could not be triggered.';
    }
}

sub process_file_upload {
    my ( $abs_dir, $file_param, $upload_fh ) = @_;

    my $safe_filename = sanitize_filename($file_param);
    return ( status => 'rejected', path => $file_param, message => 'Invalid filename' )
      if $safe_filename eq '';
    return ( status => 'rejected', path => $safe_filename, message => 'Unsupported file type' )
      if !is_uploadable_file($safe_filename);

    my $final_path = File::Spec->catfile( $abs_dir, $safe_filename );
    my %result = safe_write_file( $final_path, $upload_fh );
    return ( status => $result{status}, path => $safe_filename, message => $result{reason} // '' );
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

    my $upload_section = qq{<div class="btn-group"><a href="/music/import" class="btn btn-primary">Import artist or album folder</a></div>\n};
    if ( can_upload($rel_path) ) {
        $upload_section .= qq{<div class="btn-group"><a href="/music/upload?path=$enc_path" class="btn btn-secondary">Upload files to this folder</a></div>\n};
    }
    elsif ( $depth == 0 ) {
        $upload_section .= qq{<p class="form-hint">Select an artist or album folder on the import page to upload many files at once.</p>\n};
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

    my $rel_path = normalize_music_path( scalar $q->param('path') // '' );

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

    my $max_mb = $main::config->{music_upload_max_mb} // 100;
    my @entries = upload_file_entries($q);

    if ( !@entries ) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = "No file received or file size exceeds the ${max_mb} MB limit.";
        return;
    }

    my %summary = (
        dest_path => $rel_path,
        created   => [],
        skipped   => [],
        rejected  => [],
        errors    => [],
    );

    for my $entry (@entries) {
        my %result = process_file_upload( $abs, $entry->{name}, $entry->{fh} );
        my $path   = $result{path} // $entry->{name};

        if ( $result{status} eq 'created' || $result{status} eq 'overwritten' ) {
            push @{ $summary{created} }, $path;
        }
        elsif ( $result{status} eq 'skipped' ) {
            push @{ $summary{skipped} }, $path;
        }
        elsif ( $result{status} eq 'rejected' ) {
            push @{ $summary{rejected} }, $path;
        }
        else {
            push @{ $summary{errors} }, { path => $path, message => $result{message} // 'Upload failed' };
        }
    }

    apply_upload_summary( $resp, $q, \%summary );
}

sub show_import_form {
    my ( $resp, $q ) = @_;

    my @artists = list_artists();
    my $options = qq{<option value="">Select existing artist...</option>\n};
    for my $artist (@artists) {
        my $enc = html_escape_text( $q, $artist );
        $options .= qq{<option value="$enc">$enc</option>\n};
    }

    my $max_mb    = $main::config->{music_import_max_mb} // 500;
    my $batch_sz  = $main::config->{music_import_batch_size} // 25;
    my @ext       = ( allowed_extensions(), allowed_image_extensions() );
    my %seen;
    @ext = grep { !$seen{lc($_)}++ } @ext;
    my $ext_text  = join( ', ', map { ".$_" } @ext );

    $resp->{variables}{artist_options}   = $options;
    $resp->{variables}{max_import_mb}    = $max_mb;
    $resp->{variables}{import_batch_size} = $batch_sz;
    $resp->{variables}{extensions_text}  = $ext_text;

    main::render_page(
        $resp,
        content_template => '../templates/music_import.html',
        title            => 'Import Music',
        active_page      => 'music',
    );
}

sub import_tree {
    my ( $resp, $q ) = @_;

    my $mode           = scalar $q->param('import_mode') // 'artist';
    my $source_artist  = sanitize_dirname( normalize_text( scalar $q->param('source_artist') // '' ) );
    my $source_album   = sanitize_dirname( normalize_text( scalar $q->param('source_album') // '' ) );
    my $target_artist  = sanitize_dirname( normalize_text( scalar $q->param('target_artist') // '' ) );
    my $trigger_rescan = scalar $q->param('trigger_rescan') // '';
    my $import_count   = 0 + ( scalar $q->param('import_count') // 0 );

    if ( $mode ne 'artist' && $mode ne 'album' ) {
        return import_json_error( $resp, $q, 'Invalid import mode.' );
    }

    if ( $mode eq 'artist' ) {
        return import_json_error( $resp, $q, 'Artist name is required.' )
          if $source_artist eq '' || !validate_dirname($source_artist);
    }
    else {
        return import_json_error( $resp, $q, 'Target artist is required.' )
          if $target_artist eq '' || !validate_dirname($target_artist);
        return import_json_error( $resp, $q, 'Album name is required.' )
          if $source_album eq '' || !validate_dirname($source_album);
    }

    if ( !$import_count ) {
        return import_json_error( $resp, $q, 'No files were received in this batch.' );
    }

    my %summary = (
        created  => [],
        skipped  => [],
        rejected => [],
        errors   => [],
    );

    for my $i ( 0 .. $import_count - 1 ) {
        my $relpath = normalize_text( scalar $q->param("import_path_$i") // '' );
        my $fh      = $q->upload("import_file_$i");

        if ( !$fh ) {
            push @{ $summary{errors} }, { path => $relpath, message => 'Missing upload data' };
            next;
        }

        $relpath =~ s{\\}{/}g;
        if ( $relpath eq '' ) {
            push @{ $summary{errors} }, { path => '(empty)', message => 'Missing relative path' };
            next;
        }

        if ( is_skipped_import_file($relpath) ) {
            push @{ $summary{rejected} }, $relpath;
            next;
        }

        my $dest_rel = map_import_destination( $mode, $source_artist, $source_album, $target_artist, $relpath );
        if ( $dest_rel eq '' ) {
            push @{ $summary{errors} }, { path => $relpath, message => 'Could not map destination path' };
            next;
        }

        my @parts = split_path_parts($dest_rel);
        my $filename = pop @parts;
        if ( !defined $filename || $filename eq '' ) {
            push @{ $summary{errors} }, { path => $relpath, message => 'Invalid destination file path' };
            next;
        }

        if ( !validate_path_parts(@parts) ) {
            push @{ $summary{errors} }, { path => $relpath, message => 'Invalid folder name in path' };
            next;
        }

        my $dir_rel = join_path_parts(@parts);
        my $abs_dir = abs_path_for_rel($dir_rel);
        if ( !defined $abs_dir ) {
            push @{ $summary{errors} }, { path => $relpath, message => 'Destination path is not allowed' };
            next;
        }

        if ( !-d $abs_dir && !ensure_parent_dirs( File::Spec->catfile( $abs_dir, $filename ) ) ) {
            push @{ $summary{errors} }, { path => $relpath, message => 'Could not create destination folders' };
            next;
        }

        my $safe_filename = sanitize_filename($filename);
        if ( $safe_filename eq '' ) {
            push @{ $summary{rejected} }, $relpath;
            next;
        }

        if ( !is_uploadable_file($safe_filename) ) {
            push @{ $summary{rejected} }, $relpath;
            next;
        }

        my $final_path = File::Spec->catfile( $abs_dir, $safe_filename );
        my %result = safe_write_file( $final_path, $fh );

        if ( $result{status} eq 'created' || $result{status} eq 'overwritten' ) {
            push @{ $summary{created} }, $dest_rel;
        }
        elsif ( $result{status} eq 'skipped' ) {
            push @{ $summary{skipped} }, $dest_rel;
        }
        else {
            push @{ $summary{errors} }, {
                path    => $dest_rel,
                message => $result{reason} // 'Upload failed',
            };
        }
    }

    if ( $trigger_rescan eq '1' && @{ $summary{created} } ) {
        maybe_trigger_rescan($resp);
    }

    import_json_result( $resp, $q, \%summary );
}

sub import_json_error {
    my ( $resp, $q, $message ) = @_;
    import_json_result(
        $resp, $q,
        {
            ok       => JSON::PP::false,
            error    => $message,
            created  => [],
            skipped  => [],
            rejected => [],
            errors   => [],
        }
    );
}

sub import_json_result {
    my ( $resp, $q, $summary ) = @_;

    my $payload = {
        ok       => ( defined $summary->{error} ? \0 : \1 ),
        created  => $summary->{created}  // [],
        skipped  => $summary->{skipped}  // [],
        rejected => $summary->{rejected} // [],
        errors   => $summary->{errors}   // [],
        rescan   => $resp->{variables}{rescan_note} // '',
    };
    $payload->{error} = $summary->{error} if defined $summary->{error};

    print $q->header(
        -type    => 'application/json; charset=UTF-8',
        -charset => 'utf-8',
    );
    print encode_json($payload);
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
