use strict;
use warnings;
use Data::Dumper;


my $img_dir_path='/var/www/images/gallery1';

    opendir(my $dh, $img_dir_path) or die "Could not open directory: $!";
    my @images = grep { /\.(?:jpe?g|png|gif|webp)$/i } readdir($dh);
    closedir($dh);
    opendir($dh, $img_dir_path) or die "Could not open directory: $!";
    my @directories = grep { -d "$img_dir_path/$_" && $_ !~ /^\.\.?$/ } readdir($dh);
    closedir($dh);
    
print Dumper \@directories;
