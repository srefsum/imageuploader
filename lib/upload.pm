package upload;
use strict;
use warnings;
use Data::Dumper;
use File::Basename;


sub upload {
    my $resp = shift;
    my $q    = shift;
    
    # Retrieve parameters
    my $dir_key             = $resp->{Params}{dir_key} || '';
    my $base_upload_path    = $resp->{Params}{directory} || '';
    my $file_param          = $resp->{Params}{file}   || '';

     # Retrieve the filehandle
    my $upload_filehandle = $q->upload('filename');

    if ( !$upload_filehandle ) {
        print "<h3>Error: No file handle received or file size exceeds threshold.</h3>";
        exit;
    }

    # Clean and untaint the remote file name
    my $safe_filename = basename($file_param);
    $safe_filename =~ s/[^A-Za-z0-9._-]//g; # Keep only secure characters

    if ( $safe_filename =~ /^([A-Za-z0-9._-]+)$/ ) {
        $safe_filename = $1; # Untainted safe string
    } else {
        print "<h3>Error: Invalid characters found in filename.</h3>";
        exit;
    }

    my $final_output_path;
    # Build the complete local destination filepath
    if (defined($resp->{Params}{sub})) {
        $final_output_path = $base_upload_path . '/'. $resp->{Params}{sub} . '/' . $safe_filename;
    } else {
        $final_output_path = "$base_upload_path/$safe_filename";
    }
    print "<h3>$final_output_path</h3>";

    # Open the target file descriptor and stream the file contents in binary mode
    open( my $out_fh, '>', $final_output_path ) or die "Cannot write file: $!";
    binmode $out_fh;

    my $buffer;
    # Stream blocks of 16KB rather than diamond operators to avoid script crashes on large rows
    while ( read( $upload_filehandle, $buffer, 16384 ) ) {
        print $out_fh $buffer;
    }

    close $out_fh;

    print "<h3>Success!</h3>";
    print "<p>File has been safely uploaded to: <b>$dir_key</b> folder.</p>";

}
1;
