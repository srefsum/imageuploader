package showimages;
use strict;
use warnings;


sub showImages {
    my $resp = shift;
    my $q = shift;
    
    my $folder = $resp->{Params}{folder};
    my $img_dir_path = %main::allowed_dirs{$folder}{directory};

    # The matching URL path that the browser uses to load the images
    my $img_url_path = '/serve?directory=' . $folder . '&file=';

    # 3. Read and filter files from the directory
    opendir(my $dh, $img_dir_path) or die "Could not open directory: $!";
    my @images = grep { /\.(?:jpe?g|png|gif|webp)$/i } readdir($dh);
    my @directories = grep { -d "$dir/$_" && $_ !~ /^\.\.?$/ } readdir($dh);
    closedir($dh);

    # 4. Generate the HTML response
    print $q->header(-type => 'text/html', -charset => 'UTF-8');
    print $q->start_html(
        -title => 'Image Gallery',
        -style => { -code => '
            .gallery { display: flex; flex-wrap: wrap; gap: 15px; }
            .gallery-item { border: 1px solid #ccc; padding: 5px; text-align: center; }
            .gallery-item img { max-width: 200px; max-height: 200px; display: block; }
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
    
    
    if (@directories) {
        print "<ul>\n";
        foreach my $dir (sort @directories) {
            next if $dir =~ /^\./;
            # escape_html prevents XSS vulnerabilities if folder names contain bad characters
            print "  <li>📁 " . $q->escape_html($dir) . "</li>\n";
        }
        print "</ul>\n";
    } else {
        print $q->p({-class => 'empty'}, 'No subdirectories found.');
    }
    print "<br>\n";

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