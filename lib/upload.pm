package upload;
use strict;
use warnings;
use File::Basename;

sub upload {
    my $resp = shift;
    my $q    = shift;

    my $dir_key          = $resp->{Params}{dir_key} || '';
    my $base_upload_path = $resp->{Params}{directory} || '';
    my $file_param       = $resp->{Params}{file} || '';

    my $upload_filehandle = $q->upload('filename');

    if (!$upload_filehandle) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = 'No file received or file size exceeds the 20 MB limit.';
        return;
    }

    if (!defined($main::allowed_dirs{$dir_key})) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = 'Invalid destination directory.';
        return;
    }

    my $safe_filename = basename($file_param);
    $safe_filename =~ s/[^A-Za-z0-9._-]//g;

    if ($safe_filename !~ /^([A-Za-z0-9._-]+)$/) {
        $resp->{variables}{result_type}    = 'error';
        $resp->{variables}{result_message} = 'Invalid characters found in filename.';
        return;
    }
    $safe_filename = $1;

    my $final_output_path;
    if (defined($resp->{Params}{sub})) {
        $final_output_path = $base_upload_path . '/' . $resp->{Params}{sub} . '/' . $safe_filename;
    } else {
        $final_output_path = "$base_upload_path/$safe_filename";
    }

    open(my $out_fh, '>', $final_output_path) or die "Cannot write file: $!";
    binmode $out_fh;

    my $buffer;
    while (read($upload_filehandle, $buffer, 16384)) {
        print $out_fh $buffer;
    }
    close $out_fh;

    my $description = $main::allowed_dirs{$dir_key}{description};
    $resp->{variables}{result_type}    = 'success';
    $resp->{variables}{result_message} = "File <strong>$safe_filename</strong> was uploaded to <strong>$description</strong>.";
    $resp->{variables}{dir_key}        = $dir_key;
}

1;
