package CGI::Dispatch;

=head1 NAME

CGI::Dispatch - Add-on module to CGI (or CGI::Fast) to dispatch CGI
calls to appropriate procedures.

(Should as time passes attempt to support full REST?)

=head1 SYNOPSIS

  use CGI::Dispatch 'url';

  url "/" => \&index;

The URL must start in '/'.

Pass HTTP headers as -header, prefixed by - and with the other -'s
(optionally) replaced by _.  If the -'s in the middle are not replaced
by _ then the whole string must be quoted as in the third example below.

Pass CGI meta variables in all upper case.

  url "/getRRD" => \&getRRD,
      -accept => 'text/json' );

  url "/updateRRD" => \&updateRRD,
      REQUEST_METHOD => 'POST',
      -content_type => 'text/json';

  url "/updateRRD" => \&updateRRD,
      REQUEST_METHOD => 'POST',
      '-content-type' => 'text/json';

or

  url "/getStuff" => sub { ... },
      ... ;

Please note that only GET queries will match unless there is an
explicit specification of (all the) methods that will work.  This is
to avoid calling handling procedures that are not explicitly prepared
to act correctly on POST or DELETE or whatever other HTTP or HTTP
related method that might conceivably be invoked.

In the updateRRD example above only POST is appropriate since the
query changes, updates, the database.  And the content must be JSON
because that is what we understand.

Login can only be done over HTTPS (right?):

  url "/login" => \&do_login,
      scheme => 'HTTPS';

This does not generate a redirect to HTTPS for accesses to /login by
HTTP.  Use this pseudo-code-handler to do that:

  url "/login" => "redirect HTTPS",
      scheme => 'HTTP';

Note that 'scheme' does not start in '-' as the other header matchings
do.  Redirect can also be used like this:

  url "/getRRD" => "redirect /newGet";

to redirect to some other url inside the applications own url space or

  url "/getRRD" => "redirect http://oss.oetiker.ch/rrdtool/download.en.html";

to redirect to somewhere else entirely.

Then when the time comes to do work you do:

  CGI::Dispatch::do;                 # Will get request with "new CGI"

  CGI::Dispatch::do(new CGI);        # You got the request

  CGI::Dispatch::do(new CGI::Fast);  # And now we're fast CGI!

or just

  CGI::Dispatch::loop();             # Fast CGI only

=head1 DESCRIPTION

This is a bit like CGI::Dispatcher::Simple but with more sugar.

=head2 MATCHING ORDER

Matching is done in the order of the url calls and therefore the
example sequence is silly, the first url call is for / with no
qualifications so this would match all queries.  Put your call for /
at the end.

=head2 SIMPLIFIED REDIRECTS

By specifying one of

  url "/foo" => 'redirect /bar';

  url "/login" => 'redirect HTTPS',
       scheme => 'HTTP';

  url "/getaway" => 'http://paris.fr/';

you get simplified redirects handled automatically.  The two first
forms preserves the PATH_INFO and QUERY_STRING.  The last form
preserves nothing it just sends the hard coded url.

The second form can also be "redirect HTTP" though I'm not sure if
that's suitable in any context after Snowden.

=head2 HANDLING PROCEDURE

The handler procedures such as &index, &getRRD, &updateRRD gets called
upon a match. It is called with two arguments:

* First is the matched CGI::Dispatch::match object.
* Second is the CGI (or CGI::Fast) object for the current request.

Thereafter it has the full CGI API available (use the object oriented
API(?)) to examine the request and act on it.

=head2 TESTING AND DEBUGGING

You can test your script in the same ways you can test regular CGI
scripts.  The command line becomes a bit long but:

    REMOTE_USER=niclan PATH_INFO=/upate  ./web/rrd foo=1

This will be just one one time through the event loop in
CGI::Dispatch::loop, or one call do CGI::Dispatch::do.

REQUEST_METHOD defaults to GET if not set, and can be overridden by
setting e.g., REQUEST_METHOD=POST.

If not set, SERVER_NAME and SCRIPT_NAME defaults to "(no server name)"
and "(no script name)" respectively.

You can set the special variable POSTDATA to contain the document
(long string) you would post in a POST request.

When running on the command line the QUERY_STRING environment variable
is not set according to the command line, it is unset.  If you need it
you must set it yourself - i.e. it must be supplied both as arguments
and in the environment.

=cut

use v5.10.1;
use strict;
use warnings;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

=head2 DEPENDENCIES

This module depends on Perl 5.10 or later, CGI, Time::HiRes and
Path::Tiny.

If you use CGI::Dispatch::loop() it will also need CGI::Fast.

=cut

use CGI;
use Carp;
use Path::Tiny;
use Time::HiRes;
use Data::Dumper;

require Exporter;
our @ISA       = ( qw(Exporter) );
our @EXPORT_OK = ( qw(url apilist enableoptions) );

our $VERSION = 0.1;

# Matches, in the order submitted.  Make "our" in order to inspect
# from test suite

our @ordered = ();

=head1 ERROR HANDLING

The variable $CGI::Dispatch::dieonerror controls how the library acts
on errors.  It defaults to 2.

If set to 2 then confess from the L<Carp> module will be called on
errors, resulting in a stack trace and program termination.

If set to 1 then errors in the library will be fatal by calling die
with the error message.

If the value is 0 and you collect the return value of your calls to
the url function then the errors will be silent.  If you do not
collect the return value the error will be printed using L<warn>, but
otherwise not be fatal.

If the value is -1 then the library will be silent about errors and
you have to check for them.

See L<CGI::Dispatch::error> on how to retrieve the error message.

=cut

our $dieonerror = 2;
our $error = undef;
our $optionsmethod = undef;

sub _set_error {
    # $wa = the callers wantarray, used to check if the call site checks
    # the return code. If it does not we might make noises.

    my ($wa) = shift @_;

    $error = join(" ", @_);

    # given ($dieonerror) {
    #     when ( 2) { confess $error }
    #     when ( 1) { die $error, "\n" }
    #     when (-1) { 1 }
    #     default   { warn $error,"\n" if ! defined $wa }
    # }
    for ($dieonerror) {
        if    ($_ == 2) { confess $error }
        elsif ($_ == 1) { die $error, "\n" }
        elsif ($_ ==-1) { 1 }
        else   { warn $error,"\n" if ! defined $wa }
    }
    return 0;
}

my  @metavars = ( qw(AUTHORIZATION AUTH_TYPE CONTENT_LENGTH CONTENT_TYPE
                   GATEWAY_INTERFACE PATH_INFO PATH_TRANSLATED
                   QUERY_STRING REMOTE_ADDR REMOTE_HOST REMOTE_IDENT
                   REMOTE_USER REQUEST_METHOD SCRIPT_NAME SERVER_NAME
                   SERVER_PORT SERVER_PROTOCOL SERVER_SOFTWARE ) );

sub _get_environment {

    # Collect all the right environment variables and do not use the
    # environment again anywhere else.

    my $scheme = 'HTTP';
    $scheme = 'HTTPS' if exists $ENV{'HTTPS'};

    my $h = {};

    # Make changes in te environment, it's less surprising for the API
    # user that uses $ENV{SCRIPT_NAME} to log something and such.

    # Default the PATH to /, it's more acceptable all around.
    $ENV{PATH_INFO}      //= '/';
    $ENV{SERVER_NAME}    //= "(no server name)";
    $ENV{SCRIPT_NAME}    //= "(no script name)";
    $ENV{REQUEST_METHOD} //= "GET";

    foreach my $H (grep {/^HTTP_.*/} keys %ENV) {
        my $lch = lc $H;
        $lch =~ s/^HTTPS?_//;
        $h->{$lch} = $ENV{$H};
    }

    my $m = {};

    foreach my $mv (@metavars) {
        $m->{$mv} = $ENV{$mv}
    }

    return ($scheme, $h, $m);
}


sub _callsite {
    my ($depth) = @_;

    my ($package, $filename, $line, $sub) = caller($depth+1);
    return "at ${package}::$sub($filename:$line)";
}


=head1 API

=head2 CGI::Dispatch::error();

Return error message from last error - a non-localized string.  Resets
the error.

=cut

sub error {
    my $e = $error;

    $error = undef;

    return $e;
}

=head2 url %args  (CGI::Dispatch::url)

Only exported if you specify

  use CGI::Dispatch 'url';

Contents of %args:

=head3 A path => code reference

E.g.

  /getRRD => \&getrrd

A path relative to the cgi script, when matched calls the referenced
code.  See examples at top.

You can also specify redirects in a simple manner, see below for more
information.

=head3 -http-header => value

Many of these can be specified and they act as a filter/qualifier for the
path matching.  Therefore one path can have several matches specified
by L<url> calls.

See
L<http://code.tutsplus.com/tutorials/http-headers-for-dummies--net-8039>
or L<http://tools.ietf.org/html/rfc2616> for more about HTTP headers.
Headers and their values are matched case insensitively.

E.g.

  -accept => 'text/plain'

or

  -Accept => [ 'text/xml', 'text/json' ]

to match any of those values.

=head3 CGI_meta_variable => value

E.g.

  REQUEST_METHOD => 'GET'

Like -http-header this filters and qualifies the request that will
match this path.  See L<http://www.ietf.org/rfc/rfc3875> for a list of
meta-variable-names.

The meta variable REQUEST_METHOD is special in that there is a default
value which is 'GET'.  So by default NO 'POST' queries will match
anything.  Also supports a array like -http-header.  So

  REQUEST_METHOD => [ 'GET', 'POST' ],

=cut

sub url {
    my (%args) = @_;

    my $url = undef;

    # Make a object
    my $match = bless {}, "CGI::Dispatch::match";

    foreach my $a (keys %args) {
        # given ($a) {
        #     when (/^$/)        { $match->set_url   ( $a, $args{$a}) }
        #     when (/^\//)       { $match->set_url   ( $a, $args{$a}) }
        #     when (/^scheme$/i) { $match->set_scheme( $args{$a}) }
        #     when (/^-/ )       { $match->set_header( $a, $args{$a}) }
        #     when (/^[A-Z]/)    { $match->set_meta  ( $a, $args{$a}) }
        #     default {
        #         return _set_error(wantarray,
        #                           "Unrecognized argument: '$a' => $args{$a}!");
        #     }
        for ($a) {
            if     ($_ =~ /^$/)        { $match->set_url   ( $a, $args{$a}) }
            elsif  ($_ =~ /^\//)       { $match->set_url   ( $a, $args{$a}) }
            elsif  ($_ =~ /^scheme$/i) { $match->set_scheme( $args{$a}) }
            elsif  ($_ =~ /^-/ )       { $match->set_header( $a, $args{$a}) }
            elsif  ($_ =~ /^[A-Z]/)    { $match->set_meta  ( $a, $args{$a}) }
            else {
                return _set_error(wantarray,
                                  "Unrecognized argument: '$a' => $args{$a}!");
            }
        }
    }

    my $error = $match->finalize();

    return _set_error(wantarray, $error) if $error;

    push @ordered, $match;
    # print Dumper \@ordered;

    return 1;
}

=head2 CGI::Dispatch::do($cgireq);

Call as one of

  CGI::Dispatch::do();

  CGI::Dispatch::do(new CGI);

  CGI::Dispatch::do(new CGI::Fast);

If you don't supply a CGI request object then one is made doing "new
CGI".

=cut

sub do {
    my ($cgireq) = @_;

    $cgireq //= new CGI;  # Any request object given? get one.

    my ($scheme, $h, $m) = _get_environment;

    my $pathparam = $m->{PATH_INFO};
    goto fallthru if $pathparam eq '';

    my $method = $m->{REQUEST_METHOD};

    # Debugging aids
    $cgireq->param('SCHEME', $scheme);
    $cgireq->param('POSTDATA', $ENV{POSTDATA}) if exists $ENV{POSTDATA};

    # Find a match
    # print Dumper \@ordered;
    foreach my $candidate (@ordered) {
        if ( $candidate->is($cgireq, $scheme, $h, $m) ) {
            $candidate->dispatch($cgireq, $m);
            return;
        }
    }

  fallthru:
    # Default handler for now
    print $cgireq->header("text/plain", "400 Unrecognized request"),
      "Could not find a match for\n",
        "Scheme: $scheme\n",
          "Headers: ",Dumper($h),
            "Meta-variables: ",Dumper($m);
}

# Test access
sub apilist {
    return(\@ordered);
}


sub enableoptions {
    $optionsmethod = shift;
}




=head2 CGI::Dispatch::loop();

Main loop for a CGI::Fast program.  Returns when it's time to exit the
program so you can do cleanups.  No arguments, no return value.

=cut

sub loop {
    # Longest path first shortest last
    @ordered =  sort { $b->{len} <=> $a->{len} } @ordered;

    # Don't want to load or require CGI::Fast until it's needed.
    eval "use CGI::Fast;";

    while (my $r = new CGI::Fast) {
        CGI::Dispatch::do($r);
    }
}


package CGI::Dispatch::match;

# Mostly internal package

use Path::Tiny;
use Data::Dumper;

sub dispatch {
    my ($self, $cgireq, $m) = @_;

    die "[FATAL INTERNAL ERROR] There is no handler for in ",Dumper $self
      if ! exists $self->{method} or ! defined $self->{method};

    my $method = $self->{method};
    my $r = ref $method;

    my $purl = $m->{SERVER_NAME}.$m->{SCRIPT_NAME};
    $purl .= "/".$m->{PATH_INFO} if defined $m->{PATH_INFO};

    my $qurl = '';
    $qurl = "?".$m->{QUERY_STRING} if defined $m->{QUERY_STRING};

    if ($r eq 'CODE') {
        # User supplied handler
        if (($m->{REQUEST_METHOD} eq 'OPTIONS') and (defined($optionsmethod))) {
            &$optionsmethod($self, $cgireq);
        } else {
            &$method($self, $cgireq);
        }
        return;
    } elsif ($method =~ m~^redirect (/.*)$~) {
        # Simplified redirects
        my $u = $1;
        print $cgireq->redirect("$m->{SCRIPT_NAME}$u$qurl");
        return;
    } elsif ($method =~ m~redirect (HTTPS?)$~) {
        my $s = $1;
        print $cgireq->redirect("$s://$purl$qurl");
        return;
    } elsif ($method =~ m/redirect (.*)$/) {
        print $cgireq->redirect($1);
        return;
    }

    die "[FATAL] It turns out I don't know how to handle ".Dumper($self);
}

# Build objects for each "url" call that can later be matched by
# incoming requests.

sub set_url {
    # Set the URL of the object
    my ($self, $url, $method) = @_;

    my $at = CGI::Dispatch::_callsite(1);

    return _set_error(wantarray,"Undefined method for $url")
      if ! defined $method;

    $self->{url}    = $url;
    $self->{len}   = length $url;
    $self->{method} = $method;

    return 0;
}


sub set_header {
    # All other properties than the URL (and access scheme) are stored in arrays
    my ($self, $key, $value) = @_;

    $key = lc $key;

    return _set_error("Header specifications must start in '-'")
      if substr($key, 0, 1) ne '-';

    # Allowing -content_type because perl thinks -content-type is math
    # unless you quote it '-content-type'.

    $key =~ y/_/-/;

    if (ref $value eq 'ARRAY') {
        $self->{$key} = $value;
    } else {
        $self->{$key} = [ $value ];
    }
}


sub set_scheme {
    # HTTP or HTTPS.  Only one allowed, if you don't care, don't give
    # any.

    my($self, $value) = @_;

    #given ($value) {
    #    when (['HTTP', 'HTTPS']) { 1 }
    #    default { _set_error("Unknown scheme '$value'"); }
    #}
    
    for ($value) {
        if ($_ eq 'HTTP' or $_ eq 'HTTPS') { 1 }
        else { _set_error("Unknown scheme '$value'"); }
    }

    $self->{scheme} = $value;
}


sub set_meta {
    # All other properties than the URL are stored in arrays
    my ($self, $key, $value) = @_;

    $key = uc $key;

    if (ref $value eq 'ARRAY') {
        $self->{$key} = $value;
    } else {
        $self->{$key} = [ $value ];
    }
}

sub get_meta {
    # get meta properties stored in arrays
    my ($self, $key) = @_;

    return($self->{$key}) if (defined ($self->{$key}));
    return($self->{uc($key)}) if (defined ($self->{uc($key)}));
    return;
}

sub finalize {
    # Done building the object based on the call, check if it contains
    # what we need.  Return a error code of 0 if all is good,
    # otherwise a string describing the problem.
    my ($self) = @_;

    my $at = CGI::Dispatch::_callsite(1);

    # There must be a URL, no default is applicable
    return "No URL given for 'url' call $at"
      if ! defined $self->{url};

    return "No method for $self->{url} called $at"
      if ! defined $self->{method};

    # There must be a method, GET is the default.
    $self->set_meta('REQUEST_METHOD', 'GET')
      if ! defined $self->{'REQUEST_METHOD'};

    # Add OPTIONS to all 
    push @{$self->{'REQUEST_METHOD'}}, 'OPTIONS';
    
    $self->{path} = path($self->{url});

    return 0;
}


sub check_stuff {
    my ( $value, $containedin, $m ) = @_;

    $containedin =~ y/-/_/;

    return 0 if ! exists $m->{$containedin};

    my @vals = ( $m->{$containedin} );

    # HTTP headers may contain comma separated value lists
    if ( $containedin =~ m/HTTP_/ and
         $m->{$containedin} =~ m/,/ ) {
        @vals = split( /\s*,\s*/, $m->{$containedin} );
    }

    foreach my $v (@$value) {
        #return 1 if $v ~~ @vals;
        return 1 if grep { $v =~ /$_/ } @vals;
    }

    return 0;
}


sub is {
    my ($self, $cgireq, $scheme, $h, $m) = @_;
    
    # print Dumper $self;

    foreach my $p (keys %{$self}) {
        # print $p . " ";
        # given ($p) {
        #     when ('len')      { 1 }
        #     when ('method')   { 1 }
        #     when ('path')     { 1 }
        # 
        #     when ('url')      { # The path component contains a object which
        #                         # can check path hierarchy.
        # 
        #                        # #print " Test for : " . $self->{'path'}->stringify() . " vs " . $m->{PATH_INFO}  ;
        #                        # if ($m->{PATH_INFO} =~ /[&\?]/) {
        #                        #   my ($sub_path) = split (/[&\?]/, $m->{PATH_INFO});
        #                        #   if ($self->{'path'}->stringify() ne $sub_path) {
        #                        #     #print " : Negative\n";
        #                        #     return 0 ;  
        #                        #   }
        #                        # } else {
        #                        #     if ($self->{'path'}->stringify() ne $m->{PATH_INFO}) {
        #                        #         #print " : Negative\n";
        #                        #         return 0 ;
        #                        #     }
        #                        # }
        #                         
        #                         
        #                         if ($m->{PATH_INFO} =~ /[&\?]/) {
        #                           my ($sub_path) = split (/[&\?]/, $m->{PATH_INFO});
        #                           return 0 if (! $self->{'path'}->subsumes($sub_path));  
        #                         } else {return 0 if (! $self->{'path'}->subsumes($m->{PATH_INFO}))}
        #                       }
        # 
        #     when ('scheme')   { return 0 if ( ( $self->{$p} eq 'HTTPS' and
        #                                         $scheme ne 'HTTPS' ) or
        #                                       ( $self->{$p} eq 'HTTP' and
        #                                         $scheme ne 'HTTP' ) ) }
        # 
        #     when (/^-/)       { return 0 if ! check_stuff( $self->{$p},
        #                                                    uc "HTTP$p",
        #                                                    $m ) }
        # 
        #     when (/^[A-Z]/)   { return 0 if ! check_stuff( $self->{$p},
        #                                                    $p,
        #                                                    $m ) }
        # 
        #     default           { die "So sorry, I don't recognize: $p from",
        #                           Dumper($self),"\n"; }
        # }
        for ($p) {
            if ($_ eq 'len')        { 1 }
            elsif ($_ eq 'method')  { 1 }
            elsif ($_ eq 'path')    { 1 }

            elsif ($_ eq 'url')  { # The path component contains a object which
                                # can check path hierarchy.

                               # print " Test for : " . $self->{'path'}->stringify() . " vs " . $m->{PATH_INFO}  ;
                               # if ($m->{PATH_INFO} =~ /[&\?]/) {
                               #   my ($sub_path) = split (/[&\?]/, $m->{PATH_INFO});
                               #   if ($self->{'path'}->stringify() ne $sub_path) {
                               #     #print " : Negative  0\n";
                               #     return 0 ;  
                               #   }
                               # } else {
                               #     if ($self->{'path'}->stringify() ne $m->{PATH_INFO}) {
                               #         #print " : Negative 1\n";
                               #         return 0 ;
                               #     }
                               # }
                                
                                
                                if ($m->{PATH_INFO} =~ /[&\?]/) {
                                  my ($sub_path) = split (/[&\?]/, $m->{PATH_INFO});
                                  return 0 if (! $self->{'path'}->subsumes($sub_path));  
                                } else {return 0 if (! $self->{'path'}->subsumes($m->{PATH_INFO}))}
                              }

            elsif ($_ eq 'scheme')   { return 0 if ( ( $self->{$p} eq 'HTTPS' and
                                                $scheme ne 'HTTPS' ) or
                                              ( $self->{$p} eq 'HTTP' and
                                                $scheme ne 'HTTP' ) ) }

            elsif ($_ =~ /^-/)       { return 0 if ! check_stuff( $self->{$p},
                                                           uc "HTTP$p",
                                                           $m ) }

            elsif ($_ =~ /^[A-Z]/)   { return 0 if ! check_stuff( $self->{$p},
                                                           $p,
                                                           $m ) }

            else           { die "So sorry, I don't recognize: $p from",
                                  Dumper($self),"\n"; }
        }
    }
    #print "Positive\n";
    return 1;
}

1;

