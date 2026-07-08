package serve;
use strict;
use warnings;
use File::MimeInfo::Simple;

sub serve {
    my $resp = shift;
    my $q = shift;
    
    my $directory = $resp->{Params}{directory};
    my $filename  = $resp->{Params}{file};
    # print $directory . " " . $filename . "\n";

    # Security: Prevent directory traversal (no ../ allowed)
    if (!$filename || $filename =~ /\.\./) {
        print $q->header(-status => '400 Bad Request');
        exit;
    }

    my $found_path;
    
    if (defined($main::allowed_dirs{$directory})){
        if (defined($resp->{Params}{sub})) {
            $found_path = $main::allowed_dirs{$directory}{directory} . '/' . $resp->{Params}{sub} . '/' . $filename;
        } else {
            $found_path = $main::allowed_dirs{$directory}{directory} . '/' . $filename;
        }
    
        if (-e !$found_path) {
            $found_path = undef;
        }
    }

    if ($found_path) {
        my $mime_type = mimetype($found_path) || 'image/jpeg';
        
        # Open file in binary mode
        open(my $fh, '<:raw', $found_path) or die "Cannot open: $!";
        
        # Print headers
        print $q->header(
            -type => $mime_type,
            -content_length => -s $found_path,
            -expires => '+1d' # Cache for 1 day
        );
        
        # Stream the file
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
    my $q = shift;
    
    my $folder = $resp->{Params}{folder};
    my $img_dir_path = $main::allowed_dirs{$folder}{directory};
    
    if (!defined($main::allowed_dirs{$folder})) {
        print $q->header(-type => 'text/html', -charset => 'UTF-8');
        print $q->start_html();
        print $q->h1('$folder not available');
        print $q->end_html();
        return;
    }
    
    my $img_url_path;
    # The matching URL path that the browser uses to load the images
    if (defined($resp->{Params}{sub}) and $main::allowed_dirs{$folder}{showsubdirs} eq "Yes") {
        $img_dir_path .= "/" . $resp->{Params}{sub};
        $img_url_path = '/serve?directory=' . $folder . '&sub=' . $resp->{Params}{sub} . '&file=';
    } else {
        $img_url_path = '/serve?directory=' . $folder . '&file=';
        
    }


    # 3. Read and filter files from the directory
    opendir(my $dh, $img_dir_path) or die "Could not open directory: $!";
    my @images = grep { /\.(?:jpe?g|png|gif|webp)$/i } readdir($dh);
    closedir($dh);
    opendir($dh, $img_dir_path) or die "Could not open directory: $!";
    my @directories = grep { -d "$img_dir_path/$_" && $_ !~ /^\.\.?$/ } readdir($dh);
    closedir($dh);

    # 4. Generate the HTML response
    print $q->header(-type => 'text/html', -charset => 'UTF-8');
    print $q->start_html(
        -title => 'Image Gallery',
        -style => { -code => '
            .gallery { display: flex; flex-wrap: wrap; gap: 15px; }
            .gallery-item { border: 1px solid #ccc; padding: 5px; text-align: center; }
            .gallery-item img { max-width: 100px; max-height: 100px; display: block; }
            .filename { font-size: 12px; margin-top: 5px; color: #555; }
        '}
    );

    print $q->h1('Images Found in Directory');

    if (@images) {
        print $q->start_div({-class => 'gallery'});
        
        # Loop through filtered images and render them
        for my $img (sort @images) {
            my $encoded_img = $q->escapeHTML($img);
            my $src_url     = "$img_url_path$encoded_img";
            
            print $q->start_div({-class => 'gallery-item'});
            print $q->a({-href => $src_url}, $q->img({-src => $src_url, -alt => $encoded_img}));
            print $q->div({-class => 'filename'}, $encoded_img);
            print $q->end_div();
        }
        
        print $q->end_div();
    } else {
        print $q->p('No images found in the specified directory.');
    }

    if (!defined($resp->{Params}{sub}) ) {
        if (@directories) {
            print "<ul>\n";
            print $q->start_div({-class => 'gallery'});
            foreach my $dir (sort @directories) {
                next if $dir =~ /^\./;
                # escape_html prevents XSS vulnerabilities if folder names contain bad characters
                print $q->start_div({-class => 'gallery-item'});
                my $href = '/show?directory=images&sub=' . $q->escapeHTML($dir);
                print "  <li>📁<a href=\"$href\"> " . $q->escapeHTML($dir) . "</a></li>\n";
                print $q->end_div();
            }
            print $q->end_div();
            print "</ul>\n";
        } else {
            print $q->p({-class => 'empty'}, 'No subdirectories found.');
        }
    }
    print <<'HTML';
    <div class="form-container">
        <h2>Create Directory</h2>
        <form action="/create" method="post" enctype="multipart/form-data">
            
            <div class="form-group">
                <label for="current_dir">Current Directory:</label>
                <input type="text" id="current_dir" name="current_dir" value="images" readonly>
            </div>

            <div class="form-group">
                <label for="new_dir">New Directory Name:</label>
                <input type="text" id="new_dir" name="new_dir" placeholder="my_new_folder" required>
            </div>

            <button type="submit">Create</button>
        </form>
    </div>

HTML



    print $q->end_html();
}

1;
