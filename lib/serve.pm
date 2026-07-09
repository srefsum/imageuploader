package serve;
use strict;
use warnings;
use File::MimeInfo::Simple;

sub serve {
    my $resp = shift;
    my $q = shift;

    my $directory = $resp->{Params}{directory};
    my $filename  = $resp->{Params}{file};

    if (!$filename || $filename =~ /\.\./) {
        print $q->header(-status => '400 Bad Request');
        exit;
    }

    my $found_path;

    if (defined($main::allowed_dirs{$directory})) {
        if (defined($resp->{Params}{sub})) {
            $found_path = $main::allowed_dirs{$directory}{directory} . '/' . $resp->{Params}{sub} . '/' . $filename;
        } else {
            $found_path = $main::allowed_dirs{$directory}{directory} . '/' . $filename;
        }

        if (!-e $found_path) {
            $found_path = undef;
        }
    }

    if ($found_path) {
        my $mime_type = mimetype($found_path) || 'image/jpeg';

        open(my $fh, '<:raw', $found_path) or die "Cannot open: $!";

        print $q->header(
            -type           => $mime_type,
            -content_length => -s $found_path,
            -expires        => '+1d'
        );

        while (read($fh, my $buffer, 10240)) {
            print $buffer;
        }
        close($fh);
    } else {
        print $q->header(-status => '404 Not Found');
        print "Image not found.";
    }
}

sub showImages {
    my $resp = shift;
    my $q    = shift;

    my $folder = $resp->{Params}{folder};

    if (!defined($folder) || !defined($main::allowed_dirs{$folder})) {
        my $label = defined($folder) ? $q->escapeHTML($folder) : 'unknown';
        main::print_error_page($resp, "Directory not available: $label");
        return;
    }

    my $img_dir_path = $main::allowed_dirs{$folder}{directory};
    my $description  = $main::allowed_dirs{$folder}{description};
    my $img_url_path;

    if (defined($resp->{Params}{sub}) && $main::allowed_dirs{$folder}{showsubdirs} eq "Yes") {
        $img_dir_path .= '/' . $resp->{Params}{sub};
        $img_url_path = '/serve?directory=' . $folder . '&sub=' . $q->escapeHTML($resp->{Params}{sub}) . '&file=';
    } else {
        $img_url_path = '/serve?directory=' . $folder . '&file=';
    }

    opendir(my $dh, $img_dir_path) or die "Could not open directory: $!";
    my @images = grep { /\.(?:jpe?g|png|gif|webp)$/i } readdir($dh);
    closedir($dh);

    my @directories;
    if (!defined($resp->{Params}{sub}) && $main::allowed_dirs{$folder}{showsubdirs} eq "Yes") {
        opendir($dh, $img_dir_path) or die "Could not open directory: $!";
        @directories = grep { -d "$img_dir_path/$_" && $_ !~ /^\.\.?$/ } readdir($dh);
        closedir($dh);
    }

    my $gallery_items;
    if (@images) {
        $gallery_items = "<div class=\"gallery\">\n";
        for my $img (sort @images) {
            my $encoded = $q->escapeHTML($img);
            my $src     = $img_url_path . $encoded;
            $gallery_items .= qq{  <div class="gallery-item" data-name="} . lc($encoded) . qq{">\n};
            $gallery_items .= qq{    <a href="$src"><img class="gallery-thumb" src="$src" alt="$encoded" /></a>\n};
            $gallery_items .= qq{    <div class="gallery-filename">$encoded</div>\n};
            $gallery_items .= "  </div>\n";
        }
        $gallery_items .= "</div>\n";
    } else {
        $gallery_items = '<p class="empty-state">No images found in this directory.</p>';
    }

    my $breadcrumb = qq{<a href="/index">Home</a> / <a href="/show?directory=$folder">} . $q->escapeHTML($description) . '</a>';
    if (defined($resp->{Params}{sub})) {
        $breadcrumb .= ' / <span>' . $q->escapeHTML($resp->{Params}{sub}) . '</span>';
    }

    my $flash_message = '';
    if (defined($resp->{Params}{flash}) && $resp->{Params}{flash} eq 'dir_created') {
        $flash_message = '<div class="alert alert-success">Subdirectory created successfully.</div>';
    }

    my $upload_section = '';
    if ($main::allowed_dirs{$folder}{showsubdirs} eq 'Yes') {
        if (defined($resp->{Params}{sub})) {
            my $sub = $q->escapeHTML($resp->{Params}{sub});
            $upload_section = qq{<div class="btn-group"><a href="/getupload?directory=$folder&amp;sub=$sub" class="btn btn-primary">Upload to this folder</a></div>\n};
        } elsif (@directories) {
            $upload_section = qq{<div class="btn-group"><a href="/getupload?directory=$folder" class="btn btn-secondary">Upload to gallery root</a></div>\n};
        }
    }

    my $folder_section = '';
    if (@directories) {
        $folder_section = "<div class=\"section\"><h2>Subdirectories</h2>\n<div class=\"folder-list\">\n";
        for my $dir (sort @directories) {
            my $encoded     = $q->escapeHTML($dir);
            my $href        = '/show?directory=' . $folder . '&sub=' . $encoded;
            my $upload_href = '/getupload?directory=' . $folder . '&sub=' . $encoded;
            $folder_section .= qq{  <div class="folder-item"><div class="folder-item-actions"><a href="$href">&#128193; $encoded</a><a href="$upload_href" class="btn btn-secondary">Upload</a></div></div>\n};
        }
        $folder_section .= "</div></div>\n";
    }

    my $create_dir_form = '';
    if (!defined($resp->{Params}{sub}) && $main::allowed_dirs{$folder}{showsubdirs} eq "Yes") {
        my $encoded_folder = $q->escapeHTML($folder);
        $create_dir_form = <<"HTML";
<div class="card">
    <h2>Create subdirectory</h2>
    <form action="/create" method="post">
        <div class="form-group">
            <label class="form-label" for="current_dir">Parent directory</label>
            <input class="form-input" type="text" id="current_dir" name="current_dir" value="$encoded_folder" readonly>
        </div>
        <div class="form-group">
            <label class="form-label" for="new_dir">New directory name</label>
            <input class="form-input" type="text" id="new_dir" name="new_dir" placeholder="my_new_folder" required>
        </div>
        <button type="submit" class="btn btn-primary">Create</button>
    </form>
</div>
HTML
    }

    $resp->{variables}{page_title}      = $q->escapeHTML($description);
    $resp->{variables}{breadcrumb}        = $breadcrumb;
    $resp->{variables}{flash_message}    = $flash_message;
    $resp->{variables}{upload_section}   = $upload_section;
    $resp->{variables}{gallery_items}    = $gallery_items;
    $resp->{variables}{folder_section}   = $folder_section;
    $resp->{variables}{create_dir_form}  = $create_dir_form;

    main::render_page(
        $resp,
        content_template => '../templates/gallery.html',
        title            => "Gallery - $description",
        active_page      => $folder,
    );
}

1;
