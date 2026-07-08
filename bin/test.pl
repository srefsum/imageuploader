use strict;
use warnings;

my %resp = (
    variables => {
                    options => '<option value="images">Images Directory</option>'       . "\n" .
                               '<option value="documents">Documents Directory</option>' . "\n" .
                               '<option value="reports">Reports Directory</option>'     . "\n" 
                 }
);


our %allowed_dirs = (
    'images'    => { directory => '/var/www/images/gallery1',description => 'Images Directory' },
    'uploads'   => { directory => '/var/www/images/uploads', description => 'Upload Directory' },
    'logos'     => { directory => '/var/www/images/logos',   description => 'Logo Directory' }
);


sub ProcessFileandPrint {
    my $resp     = shift;
    my $filename = shift;
    my $indent   = shift;
    $indent //= "";
    
    
    my $output_string = "";
    
    # 1. Open the file securely using 3-argument open and lexical filehandle
    open(my $string_fh, '>', \$output_string) or die "Cannot open: $!";
    open(my $fh, '<:encoding(UTF-8)', $filename) 
        or die "Could not open file '$filename': $!";

    # 2. Read line by line
    while (my $line = <$fh>) {
        chomp $line; # Removes the trailing newline character (\n)
        
        
        # Process your line here
        if ($line =~ /^\#include\s+\"(.*)\"$/) {
            # print $string_fh $1 . "\n";
            print $string_fh ProcessFileandPrint($resp,$1,$indent);
        } elsif ($line =~ /^\#replace\s+\"(.*)\"$/) {
            my $tmp = $resp->{variables}{$1};
            $tmp =~ s/^/$indent/gm;
            print $string_fh $tmp;
        } else {
            $line =~ /^(\s+)/;
            $indent = $1;
            print $string_fh "$line\n";
        }
    }

    # 3. Close the file handle
    close($fh);
    close($string_fh);
    # print "Captured output:\n" . $output_string;
    return $output_string;
}

sub createOptions {
    my $string = "";
    for my $entry (keys %allowed_dirs) {
        $string .= sprintf ("<option value=\"%s\">%s</option>\n",$entry ,$allowed_dirs{$entry}{description});
    }
        
    return $string;
}


$resp{variables}{options} =  createOptions();
print ProcessFileandPrint(\%resp,'../templates/upload.html');