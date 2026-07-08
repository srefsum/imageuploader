package CommonApiHandler;
=head1 NAME

CommonApiHandler 

=head1 DESCRIPTION

Main part of the framework for a common microservice.
This provides common decoding af parameters and common encoding of responsebody
It also provides common api endpoints


=head1 AUTHOR
Sigvald Refsum <sigref@globalconnect.no>

=head1 CONTRIBUTORS
  
Contributor One <a1@example.com>

=cut

use warnings;
use strict;
use Data::Dumper;

use File::Basename;
use Config::General qw(ParseConfig);
use Storable qw(dclone);
use Sys::Hostname;
use Net::Domain qw(hostname hostfqdn hostdomain domainname);
use MIME::Base64;
use Time::HiRes qw(gettimeofday tv_interval);
use URI::Escape;

use FindBin;
use lib "$FindBin::Bin/../lib";
use CGI::Dispatch qw (url apilist enableoptions);

use boolean qw (false true);
use uuid;
use gclog;
use swagger;
use Heartbeat;

use Exporter;
our $VERSION = "0.2.14";
our @ISA = qw(Exporter);

our @EXPORT = qw(http_header 
             http_page_header
             http_option_header
             http_header_html
             http_header_file
             http_header_file_error
             get_http_headers
             get_http_response
             url_decode
             preInit
             allParametersUsed
             responsebody
             finelizeRequest
             getHeaderValueParams
             getSingleParams
             getSingleValueParams
             getDoubleValueParams
             getDateParameter
             dist
             explorer
             api
             version
             AddResponseDoc
        );


my $config=$main::config;

my %mime = (
    '.js'     => 'text/javascript',
    '.htm'    => 'text/html',
    '.html'   => 'text/html',
    '.png'    => 'image/png',
    '.ico'    => 'image/png',
    '.svg'    => 'image/svg+xml',
    '.css'    => 'text/css',
    '.scss'   => 'text/css',
    '.woff2'  => 'application/font-woff2',
    '.ttf'    => 'font/ttf',
    '.json'   => 'application/json',
    '.yaml'   => 'application/yaml'
);


our $log = new gclog('Request');

$log->add_structure('Server',    \&get_system_info);
$log->add_structure('event',     \&get_event_struct);
$log->add_structure('url',       \&get_url_struct, 'custom');
$log->add_structure('http',      \&get_http_struct);
$log->add_structure('service',   \&get_service_info);
$log->add_structure('tags',      \&get_tags);
$log->add_structure('trace',     \&get_trace);


local $SIG{__WARN__} = sub {
     my $message = shift;
     $log->log($message);
};

sub CommonApiHandlerInit{
    my $config=$main::config;
    if (defined($config->{ENABLEOPTIONS}) and ($config->{ENABLEOPTIONS} eq 'YES')){
        enableoptions(\&GlobalOptions);
    }
    gclog::moduleInit();
    Heartbeat::HeartbeatInit();                      
    
    url "/api/version"           => \&version;                                                                        # Display version string for cgi
    url "/api/image"             => \&image;                                                                          # Image files
    url "/api/css"               => \&css;                                                                            # Loadable css files
    url "/api/font-awesome"      => \&fontawesome;                                                                    # Loadable css files
    url "/api/script"            => \&script;                                                                         # Loadable javascript files
    url "/api/dist"              => \&dist;                                                                           # internal files for swagger
    url "/api/explorer"          => \&explorer;                                                                       # Return rudimentary api description
    url "/api/doc"               => \&api;                                                                            # Return rudimentary api description
    url "/api"                   => \&api;                                                                            # Return rudimentary api description
    url "/favicon.ico"           => \&favicon;                                                                        # Return rudimentary api description  
}



my $loglevel_match    = qr /((?:[&\?])loglevel\=?(?:(?'loglevel'(?:OFF|FATAL|ERROR|WARN|INFO|DEBUG|TRACE|ALL|DEFAULT))|(?'unknownparam'\w+)|(?'noparam'))\b)/;
my $apivalue_match    = qr /((?:[&\?])api(?:\=?)(?:(?'api'(?:request|global|api))|(?'unknownparam'\w+)|(?'noparam'))\b)/;
my $api_match         = qr /((?:[&\?])(?'api'api))/;
#my $oas_match         = qr /((?:[&\?])(?'oas'oas))/;
my $oas_match         = qr /((?:[&\?])((?'wrongparam'oas\=\w+)|(?'noparam'oas\=)|(?'oas'oas)))/;

my %param_oas = (
                    pattern       => $oas_match,                   
                    documentation => {
                        name        => 'oas',                                           
                        description => "produce oas json structure for json" .
                                       "without this parameter hardware values will be used" . 
                                       "", 
                        in          => 'query',                                          
                        required    => false,                                           
                        schema      => {
                                type    => 'string',
                                example => 'oas'
                        },
                        example    => 'oas'
                    }    
                );

my %param_apivalue = (
                    pattern       => $apivalue_match,                   
                    documentation => {
                        name        => 'api',                                           
                        description => "api select which xxx" .
                                       "", 
                        in          => 'query',                                          
                        required    => false,                                           
                        schema      => {
                            type    => 'string',
                            enum    => [qw(request global api)],
                            example => 'api=request'
                        },
                        example     => 'request'
                    }    
                );

my %param_api = (
                    pattern       => $api_match,                   
                    documentation => {
                        name        => 'api',                                           
                        description => "api select which xxx" .
                                       "", 
                        in          => 'query',                                          
                        required    => false,                                           
                        schema      => {
                                type    => 'string',
                                example => 'api'
                        },
                        example    => 'api'
                    }    
                );

# Header param definitions
our %param_trace_id = (
                    documentation => {
                        name        => 'X-TRACE-ID',                                           
                        description => "Universal unique id to trace calls through several systems" .
                                       "", 
                        in          => 'header',                                          
                        required    => false,                                           
                        schema      => {
                                type   => 'string'
                        },
                        example    => 'd263aa02-a83b-4c36-8c71-8a2ed420c591'
                    }    
                );

our %param_request_id = (
                    documentation => {
                        name        => 'X-Request-ID',                                           
                        description => "Universal unique id to trace calls through several systems" .
                                       "", 
                        in          => 'header',                                          
                        required    => false,                                           
                        schema      => {
                                type   => 'string'
                        },
                        example    => '4bf92f3577b34da6a3ce929d0e0e4736'
                    }    
                );

our %param_accept = (
                    documentation => {
                        name        => 'HTTP-Accept',                                           
                        description => "Universal unique id to trace calls through several systems" .
                                       "", 
                        in          => 'header',                                          
                        required    => false,
                        schema      => {
                                type   => 'string',
                                enum   => [('application/json', 'text/html')]
                        },
                        example    => 'text/html'
                    }    
                );

sub GlobalOptions {
    my ( $request, $httpreq ) = @_;
    print http_option_header($request, $httpreq);
}

sub http_header {
    my $resp = shift;
    my $error;
    
    my %headers = (
            -type                        => 'application/json',
            -charset                     => 'utf-8',
            -Access_Control_Allow_Origin => '*'
    );

    if (defined($resp) and ref $resp eq 'HASH'){  
        if (defined($resp->{status_api})){  
            $error = $resp->{status_api};
        } elsif (defined($resp->{status_path})){  
            $error = $resp->{status_path};
        } else {
            $error = ($resp->{status} == 0) ? 200 : $resp->{status};
            $resp->{status} = $error;
        }
        
        if ((defined($resp->{statusOveride})) and  $resp->{statusOveride} ne "") {
            $resp->{status} = $resp->{statusOveride};
            delete ($resp->{statusOveride});
        }
        
        if ($error) { $headers{'-status'} = $error; } 
        if ($error eq '401') {$headers{'-WWW_Authenticate'} =  "Basic realm='XXXXX', Bearer";}
        if (defined($resp->{Headers}{'HTTP_X_TRACE_ID'}))   {$headers{'-X-TRACE-ID'}   = $resp->{Headers}{'HTTP_X_TRACE_ID'};}
        if (defined($resp->{HeaderParams}{'X-Request-ID'})) {$headers{'-X-Request-ID'} = $resp->{HeaderParams}{'X-Request-ID'};}
    } elsif (defined($resp)){
        $headers{'-status'} = ($resp == 0) ? 200 : $resp;
    }
    return CGI::header(%headers);    
}

sub http_page_header {
    my $error = shift;
    
    if ($error) {
        return CGI::header(
            -status                      => $error,
            -type                        => 'text/html',
            -charset                     => 'utf-8',
            -Access_Control_Allow_Origin => '*'
        );

    } else {
        return CGI::header(
            -status                      => 200,
            -type                        => 'text/html',
            -charset                     => 'utf-8',
            -Access_Control_Allow_Origin => '*'
        );
    }
}

sub http_option_header {
    my $request  = shift;
    my $httpreq  = shift;
    
    my $server_name;
    my ($schemas)       = scalar $httpreq->param('SCHEME');
    $server_name     = $ENV{'SERVER_NAME'} if (defined($ENV{'SERVER_NAME'}));
    my $permitted       = lc($schemas) . '://' . $server_name;
    my $request_methods = join(',', @{$request->{REQUEST_METHOD}} );
    
    return CGI::header(
        -status                       => 200,
        -type                         => 'text/html',
        -charset                      => 'utf-8',
        -Access_Control_Allow_Headers => '*',
        -Access_Control_Allow_Methods => $request_methods,
        -Access_Control_Allow_Origin  => $permitted,
        -Access_Control_Allow_Credentials => '*'        
    );
}

sub http_header_html {
    return CGI::header(
        -status                      => 200,
        -type                        => 'text/html',
        -charset                     => 'utf-8',
        -Access_Control_Allow_Origin => '*'
    );
}

sub http_header_file {
    my $file_name = shift;
    my $type = 'text/html'; 
    if ($file_name =~ /.*(\.\w+)$/) {
        $type = $mime{$1} if (defined($mime{$1}));
    } 
    if ($type =~ /image/ ) {
        return CGI::header(
            -status                      => 200,    
            -type                        => $type,
            -expires                     => "-1d",
            -Access_Control_Allow_Origin => '*'
        );
    } else {
        return CGI::header(
            -status                      => 200,    
            -type                        => $type,
            -charset                     => 'utf-8',
            -Access_Control_Allow_Origin => '*'
        );
    }
}

sub http_header_file_error {
    return CGI::header(
        -status                      => 401,
        -type                        => 'text/html',
        -charset                     => 'utf-8',
        -Access_Control_Allow_Origin => '*'
    );
}


sub get_http_headers {
    my $httpreq  = shift;
    my $headers  = shift;
    
    my %head  = map {$_ => $httpreq->http($_)} $httpreq->http();
    
    for my $h (keys %head) {
        $headers->{$h} = $head{$h};
    }
    # Dynamic debug enabling
    if ((defined($headers->{HTTP_X_DEBUG_APP})) and ($headers->{HTTP_X_DEBUG_APP} == 1)) {
        $config->{DEBUG} = 1;
    } elsif ((defined($headers->{HTTP_X_DEBUG_APP})) and ($headers->{HTTP_X_DEBUG_APP} == 0)) {
        $config->{DEBUG} = 0;
    }
    
    if (!defined($headers->{HTTP_X_TRACE_ID})) {
        $headers->{HTTP_X_TRACE_ID} = uuid::get_trace_id();
    }
}

sub me {
    my $m = (caller(2))[3];
    $m =~ s/main\:\://;
    return($m);
}

sub url_decode {
    my $rv = shift;
    $rv =~ tr/+/ /;
    $rv =~ s/\%([a-f\d]{2})/ pack 'C', hex $1 /geix;
    return $rv;
}


sub preInit {
    my $request  = shift;
    my $httpreq  = shift;
    
    my ($schemas)  = scalar $httpreq->param('SCHEME');
    my ($postdata) = scalar $httpreq->param('POSTDATA');
    my ($putdata)  = scalar $httpreq->param('PUTDATA');
    
    my %resp       = (
        'Version'   => $main::version_string{version},
        '@Starttime' => gclog::gctime(),
        'StartTime'  => gclog::start_time(),
        'Request' => {
            'Function'        => me(),
            'Query'           => $ENV{'QUERY_STRING'},
            'Url'             => $ENV{'PATH_INFO'},
            'Request_Method'  => $ENV{'REQUEST_METHOD'},
            'schema'          => $schemas,
           },
        'Params'     => {
        },
        'Headers'    => {
        },
    );
    
    $resp{Request}{authorization}      =  $ENV{'AUTHORIZATION'} if (defined($ENV{'AUTHORIZATION'}));
    $resp{Request}{auth_type}          =  $ENV{'AUTH_TYPE'}     if (defined($ENV{'AUTH_TYPE'}));
    $resp{Request}{remote_addr}        =  $ENV{'REMOTE_ADDR'} if (defined($ENV{'REMOTE_ADDR'}));
    $resp{Request}{remote_host}        =  $ENV{'REMOTE_HOST'} if (defined($ENV{'REMOTE_HOST'}));
    $resp{Request}{remote_user}        =  $ENV{'REMOTE_USER'} if (defined($ENV{'REMOTE_USER'}));
    $resp{Request}{server_name}        =  $ENV{'SERVER_NAME'} if (defined($ENV{'SERVER_NAME'}));
    $resp{Request}{server_port}        =  $ENV{'SERVER_PORT'} if (defined($ENV{'SERVER_PORT'}));
    
    # This is a fix between the server called version and the command line called version.
    # The command line version will get the query string as part of the $ENV{'PATH_INFO'}
    # The server version will get the query string as part of the $ENV{'QUERY_STRING'}
    
    $resp{Line} = (defined($ENV{'QUERY_STRING'}) and ($ENV{'QUERY_STRING'} ne '')) ?  $ENV{'PATH_INFO'} . '?' . $ENV{'QUERY_STRING'} : $ENV{'PATH_INFO'};
	#$resp{Request}{postdata} = $postdata;
	#$resp{Request}{putdata} = $putdata;

    if (defined($request)) {
        #$resp{Documentation}{parameters}      = ();  
        $resp{Documentation}{SupportedMethod} = $request->get_meta('REQUEST_METHOD');  
        $resp{Documentation}{url}             = $request->get_meta('url');  
        if ($resp{Documentation}{url} ne $resp{Request}{Url} and 
           ($resp{Request}{Url} eq '/' or  
            $resp{Request}{Url} eq '/api'  or  
            $resp{Request}{Url} eq '/api/dist' or  
            $resp{Request}{Url} eq '/api/doc' or  
            $resp{Request}{Url} eq '/api/oas' or  
            $resp{Request}{Url} eq '/api/explorer')) {
            $resp{api} = 'global';
        } 
    }
    
    $resp{Line} = url_decode($resp{Line}); 
    my $path   = $resp{Documentation}{url};
    $resp{Line} =~ s/$path//;        # Remove the path from the request
    $resp{Line} =~ s/\/api\/doc$//;  # Remove /api/doc from the request
    $resp{Line} =~ s/\/api$//;       # Remove /api from the request
    
    if (defined($httpreq)) {
        get_http_headers($httpreq,$resp{Headers});
        #gclog::add_trace($resp{Headers}{HTTP_X_TRACE_ID});
        #$log->trace(\%resp, "Init");
    }
    # print Dumper \%resp;
    return \%resp;
}

sub allParametersUsed {
    my $string = shift;
    my $resp   = shift;    # destination    
   
    # my $path   = $resp->{Documentation}{url};
    # $string =~ s/$path//;        # Remove the path from the request
    # $string =~ s/\/api\/doc$//;  # Remove /api/doc from the request
    # $string =~ s/\/api$//;       # Remove /api from the request   

    $string = getSingleValueParams($string, \%param_apivalue, $resp, 'api');
    $string = getSingleValueParams($string, \%param_api,      $resp, 'api');
    if (defined($resp->{Params}{api})) {
        $resp->{api}    = $resp->{Params}{api};
        $resp->{status} = 200;
        delete($resp->{Params}{api});
    }
    
    #Remove and store unknown query parameters
    while (($string ne "") and ($string =~ /(&|\?)/ )) {
        if  ($string =~ /((&|\?)(\w+)=(\-\d+|\d+))/) {
            push @{$resp->{UnKnownParams}}, {test => 1, param => $3, value => $4}; 
            my $hit = $1;
            $hit    =~ s/\?/\\\?/;
            $string =~ s/$hit//;
        } elsif ($string =~ /((&|\?)(\w+)=(\w+))/)         {
            push @{$resp->{UnKnownParams}}, {test => 2, param => $3, value => $4}; 
            my $hit = $1;
            $hit    =~ s/\?/\\\?/;
            $string =~ s/$hit//;
        } elsif ($string =~ /(&|\?)(\w+)/)         {
            push @{$resp->{UnKnownParams}}, {test => 3, param => $3};
            my $hit = $1;
            $hit    =~ s/\?/\\\?/;
            $string =~ s/$hit//;
        }
    }
    #Remove and store unknown path parameters
    while (($string ne "") and ($string =~ /\/([^\/]*)/ )) {    
        if ($string =~ /(\/([^\/]*))/ ) {  
            push @{$resp->{UnKnownPathParams}}, {test => 4, param => $2};
            my $hit = $1;
            $string =~ s/$hit//;
        } 
    }

    #$log->add_structure('trace',     \&get_trace);
    if (!defined($resp->{api})) {
        $log->trace($resp, "Init");
    }
    
    if (0) {
        my ($package, $filename, $line, $subroutine)   = caller(3);
        $resp->{origin}{function}   = $subroutine;
        
       ($package, $filename, $line, $subroutine)   = caller(2);
        $resp->{origin}{file}{name} = $filename;
        $resp->{origin}{file}{line} = $line;
    }
    
    if (defined($resp->{UnKnownParams}))     {$resp->{status_api}  = 400; }
    if (defined($resp->{UnKnownPathParams})) {$resp->{status_path} = 400; }
}

sub responsebody {
    my $resp = shift;
    
    # print Dumper $resp;
    my $response_body  = JSON::to_json($resp);
    $resp->{body_size} = length($response_body);
    
    # $resp->{body_size} = strlen(json_encode($resp));
    return $response_body;
}

sub finelizeRequest {
    my $resp     = shift;
    my $method   = shift;
    my $funcType = shift;
    my $config = $main::config;
    
    #print "FinelizeRequest\n";
    #print Dumper $resp;
    # responsebody($resp);  

    if (defined($resp->{status_api}) or defined($resp->{status_path})) {
        #print "FinelizeRequest 1\n";
        # if (defined($resp->{status_api})){  
        #     print http_header($resp);
        # } elsif (defined($resp->{status_path})){  
        #     print http_header($resp);
        # }
        delete($resp->{Documentation});
        # print responsebody($resp)."\n";  
        return;
    } elsif (defined ($resp->{status}) and ($resp->{status} != 204) and ($resp->{status} != 200)) {
        #print "FinelizeRequest 2\n";
        delete($resp->{Documentation});
        print http_header($resp);
        if (!(defined($config->{DEBUG})) or ($config->{DEBUG} == 0)) {
            delete($resp->{Authorized});
            delete($resp->{Authenticated});
            delete($resp->{Authorizations});
            delete($resp->{AuthList});
            delete($resp->{HeaderParams});
            delete($resp->{Headers});
            delete($resp->{ldap});
        }
        print responsebody($resp)."\n";  
        return;
    }
    
    if (defined($resp->{api}) and ( $resp->{api} eq 'global')) {
        #print "FinelizeRequest 3\n";
        if ($config->{AUTHENTICATE} eq 'OFF')  {
            for (my $i = 0; $i < scalar @{$config->{METHODS}};$i++) {
                my $method = lc($config->{METHODS}[$i]);
                if (defined($resp->{Documentation}{$method}) and defined($resp->{Documentation}{$method}{security})) {
                    delete($resp->{Documentation}{$method}{security}); 
                } 
            }
        }
        return ($resp->{Documentation});
    } elsif (defined($resp->{api}) and ($resp->{api} eq 'api')) {
        #print "FinelizeRequest 4\n";
        print http_header($resp);
        print responsebody($resp)."\n";  
    } elsif (defined($resp->{api}) and ($resp->{api} eq 'request')) {
        #print "FinelizeRequest 5\n";
        print http_header($resp);
        print responsebody($resp)."\n";      
    } elsif (defined($method) and defined($resp->{Headers}{HTTP_ACCEPT}) and $resp->{Headers}{HTTP_ACCEPT} =~ /$funcType/) {
        #print "FinelizeRequest 6\n";
        delete($resp->{Documentation});
        print http_page_header($resp->{status});
        if (ref $method eq 'CODE') {
            &$method($resp);   
        }
    } elsif (defined($resp->{Headers}{HTTP_ACCEPT}) and (($resp->{Headers}{HTTP_ACCEPT} eq "application/json") or 
                                                         ($resp->{Headers}{HTTP_ACCEPT} eq '*/*')) ) {
        # Default  path 
        #print "FinelizeRequest 7\n";
        print http_header($resp);
        delete($resp->{Documentation});
        if (!(defined($config->{DEBUG})) or ($config->{DEBUG} == 0)) {
            delete($resp->{Authorized});
            delete($resp->{Authenticated});
            delete($resp->{Authorizations});
            delete($resp->{AuthList});
            delete($resp->{HeaderParams});
            delete($resp->{Headers});
            delete($resp->{ldap});
        }
        $log->add_structure('Response',  \&get_http_response);
        $log->trace($resp, "Response");
        
        my $json = JSON::XS->new;
        $json->convert_blessed();
        print $json->encode($resp);
        
    } elsif (!defined($resp->{Headers}{HTTP_ACCEPT})) {
        # Default  path 
        #print "FinelizeRequest 8\n";
        print http_header($resp);
        delete($resp->{Documentation});
        if (!(defined($config->{DEBUG})) or ($config->{DEBUG} == 0)) {
            delete($resp->{Authorized});
            delete($resp->{Authenticated});
            delete($resp->{Authorizations});
            delete($resp->{AuthList});
            delete($resp->{HeaderParams});
            delete($resp->{Headers});
            delete($resp->{ldap});
        }

        $log->add_structure('Response',  \&get_http_response);
        $log->trace($resp, "Response");
        my $json = JSON::XS->new;
        $json->convert_blessed();
        print $json->encode($resp);
        
    } else {
        # print "FinelizeRequest 9\n";
        delete($resp->{Documentation});
        print http_header($resp);
        print responsebody($resp)."\n";     
    }
}

sub getPostData {
    my $resp   = shift;
    
    
    if ($ENV{'REQUEST_METHOD'} eq "POST") {
        if (defined($ENV{'POSTDATA'})) {
            $resp->{postdata} =  uri_unescape($ENV{'POSTDATA'});
            $resp->{postdata_source} = 'env postdata';
            $resp->{postdata_type}   = $ENV{'CONTENT_TYPE'};
            $resp->{postdata_length} = $ENV{'CONTENT_LENGTH'};
        } else {
            my $buffer;
            read(STDIN, $buffer, $ENV{'CONTENT_LENGTH'});
            #$resp->{postdata} = uri_unescape($buffer);
            $resp->{postdata} = $buffer;
            $resp->{postdata_source} = 'stdin';
            $resp->{postdata_type}   = $ENV{'CONTENT_TYPE'};
            $resp->{postdata_length} = $ENV{'CONTENT_LENGTH'};
        } 
    } 
}


sub getPostDataValueParams {
    my $resp   = shift;
    my $name   = shift;
    

}

sub getHeaderValueParams {
    my $pattern  = shift;    # decoder
    my $resp     = shift;  
    my $name     = shift;  
    my $methods  = shift;  
    my $override = shift;  
 
    my $doc = dclone $pattern->{documentation};
    if (defined($methods))  { $doc->{methods}  = $methods   } 
    if (defined($override)) { $doc->{required} = $override; } 
    push @{$resp->{Documentation}{parameters}}, $doc;
 
    my $LookupName = uc($name);
    $LookupName =~ s/\-/_/g;
    $LookupName = 'HTTP_' . $LookupName;
 
    $resp ->{HeaderParams}{$name}   = $resp->{Headers}{$LookupName} if (defined($resp->{Headers}{$LookupName})) ;
}


sub getSingleParams {
    my $string   = shift;    # Line
    my $pattern  = shift;    # decoder
    my $resp     = shift;    # destination  
    my $name     = shift;    # param name in pattern and result
    my $methods  = shift;    # methods that can use this parameter
    my $override = shift;    # optional parameter
 
    my $doc = dclone $pattern->{documentation};
    if (defined($methods))  { $doc->{methods}  = $methods; } 
    if (defined($override)) { $doc->{required} = $override; } 
    push @{$resp->{Documentation}{parameters}}, $doc;
 
    if ($string =~ /$pattern->{pattern}/) {
        $resp ->{Params}{$name}    = $+{$name} if (defined($+{$name})) ;
        my $hit = $1;
        $hit    =~ s/\?/\\\?/;
        $string =~ s/$hit//;
    } 
    return ($string);
}

sub getSingleValueParams {
    my $string   = shift;  
    my $pattern  = shift;  
    my $resp     = shift;  
    my $name     = shift;  
    my $methods  = shift;  
    my $override = shift;  

    my $doc = dclone $pattern->{documentation};
    my $from_name = $doc->{name};
    $doc->{schema}{example} =~ s/$from_name/$name/g if (defined($doc->{schema}{example}));
    $doc->{name} = $name;
    
    if (defined($methods))  { $doc->{methods}  = $methods } 
    if (defined($override)) { $doc->{required} = $override; } 
    push @{$resp->{Documentation}{parameters}}, $doc;

    my $patt = $pattern->{pattern};
    $patt=~ s/$from_name/$name/g;
    
    if ($string =~ /$patt/) {
       $resp ->{Params}{$name}    = $+{$name} if (defined($+{$name})) ;
        my $hit = $1;
        #my $hit = $+{$name};
        $hit    =~ s/\?/\\\?/;
        $string =~ s/$hit//;
    }
    return ($string);
}

sub getDoubleValueParams {
    my $string   = shift;
    my $pattern  = shift;
    my $resp     = shift;
    my $name1    = shift;
    my $name2    = shift;
    my $methods  = shift;
    my $override = shift;
 
    my $doc = dclone $pattern->{documentation};
    if (defined($methods))  { $doc->{methods}  = $methods; } 
    if (defined($override)) { $doc->{required} = $override; } 
    push @{$resp ->{Documentation}{parameters}}, $doc;


    if ($string =~ /$pattern->{pattern}/) {
        $resp ->{Params}{$name1}    = $+{$name1} if (defined($+{$name1})) ;
        $resp ->{Params}{$name2}    = $+{$name2} if (defined($+{$name2})) ;
        my $hit = $1;
        $hit    =~ s/\?/\\\?/;
        $string =~ s/$hit//;
    }
    return ($string);
}

sub getDateParameter{
    my $line       = shift;
    my $date_match = shift;
    my $resp       = shift;
    my $p_name     = shift;
    my $date_str   = shift;
    my $time_str   = shift;
    my $methods    = shift;

    $line = getDoubleValueParams($line, $date_match, $resp, $date_str, $time_str, $methods);
    if (!defined($resp->{api})) {
        if (defined($resp->{Params}{ $date_str}) and $resp->{Params}{ $date_str} =~ /\d{4}(?:\-|\.)\d{2}(?:\-|\.)\d{2}/) {
            $resp->{Params}{ $date_str} = $3 . "\." . $2 . "\." . $1;
            $resp->{Params}{$p_name} = $resp->{Params}{ $date_str} . " " . $resp->{Params}{ $time_str}; 
        } elsif (defined($resp->{ $date_str}) and $resp->{Params}{ $date_str} =~ /(\d{2})(?:\-|\.)(\d{2})(?:\-|\.)(\d{4})/) {
            $resp->{Params}{$p_name} = $resp->{Params}{ $date_str} . " " . $resp->{Params}{ $time_str}; 
        } elsif (defined($resp->{Params}{$p_name}) and !defined($resp->{Params}{$date_str}) and !defined($resp->{Params}{ $time_str}))  {
            ($resp->{Params}{$date_str},$resp->{Params}{$time_str}) = split / / , $resp->{Params}{$p_name}; 
        } else {
            $resp->{Params}{$p_name} = $resp->{Params}{$date_str} . " " . $resp->{Params}{ $time_str}; 
        }
    }
    return $line;    
}

sub loadfile {
    my $type   = shift;
    my $binary = shift;
    
    if (!defined($binary)) {$binary = 'No'}
    
    if ($ENV{'PATH_INFO'} =~ /^\/api\/$type\/(.*)/) {
        my $file_name = $1;
        my $dir_name;
        chomp $file_name;
        ($file_name,$dir_name) = fileparse($file_name);
        if ( -e "$FindBin::Bin/../$type/$file_name" and $dir_name =~ /^\.\// ) {
            print http_header_file($file_name);
            open(my $fh, '<', "$FindBin::Bin/../$type/$file_name");
            while (my $row = <$fh>) {
                chomp $row;
                print "$row\n";
            }
            close $fh;
            return;
        }
    }
    print http_header_file_error();
}

sub favicon {
    loadfile('favicon.ico', 'binary');
}

sub image {
    loadfile('image', 'binary');
}

sub script {
    loadfile('script');
}

sub css {
    loadfile('css');
}

sub dist {
    loadfile('dist');
}

sub fontawesome {
    if ($ENV{'PATH_INFO'} =~ /^\/api\/font-awesome\/(.*)/) {
        my $file_name = $1;
        my $dir_name;
        chomp $file_name;
        ($file_name,$dir_name) = fileparse($file_name);
        if ( -e "$FindBin::Bin/../font-awesome/$dir_name/$file_name" ) {
            print http_header_file($file_name);
			if ($file_name =~ /woff2$/) {
				my $cont = '';
				open(my $fh, '<', "$FindBin::Bin/../font-awesome/$dir_name/$file_name");
				while (1) {
					my $success = read $fh, $cont, 100, length($cont);
					last if not $success;
				}
				close $fh;
				print $cont;
				return;
			} else {
				open(my $fh, '<', "$FindBin::Bin/../font-awesome/$dir_name/$file_name");
				while (my $row = <$fh>) {
					chomp $row;
					print "$row\n";
				}
				close $fh;
				return;
			}
        }
    }
    print http_header_file_error();
}


sub explorer {
    print http_header_html();
    swagger::printSwaggerPage();
}

 
sub api {
    my ($request, $httpreq) = @_;
    my %api  = %{preInit($request, $httpreq)};
    my $line = $api{Line};
    $line = getSingleParams($line,     \%param_oas,  \%api, 'oas',    ['GET']);
    allParametersUsed($line, \%api);
    
    if    ($ENV{'PATH_INFO'} =~ /^\/api\/doc\?oas$/ ) {} 
    elsif ($ENV{'PATH_INFO'} =~ /^\/api\/doc\&oas$/ ) {} 
    elsif ($ENV{'PATH_INFO'} =~ /^\/api\/doc\/oas$/ ) {} 
    elsif ($ENV{'PATH_INFO'} =~ /^\/api\/dist/ )      {} 
    elsif ($ENV{'PATH_INFO'} =~ /^\/api\/doc$/ )      {} 
    elsif ($ENV{'PATH_INFO'} =~ /^\/api\?oas$/ )      {} 
    elsif ($ENV{'PATH_INFO'} =~ /^\/api\&oas$/ )      {} 
    # elsif ($ENV{'PATH_INFO'} =~ /^\/api$/ )           {} 
    elsif ($ENV{'PATH_INFO'} =~ /^\/\?oas$/ )         {} 
    # elsif ($ENV{'PATH_INFO'} =~ /^\/$/ )              {} 
    else {
        
        my %resp = ();
        $api{status} = 400;
        $api{error} = "Unknown request path";
        delete $api{Documentation};
        print http_header(\%api);
        #print Dumper \%api;
        print JSON::to_json(\%api)."\n";        
        return;
    }
    
    
    $api{api}     = 'global'; 
    #push @{$api{oas}{paths}}, $api{Documentation}{url} => $api{Documentation};
    $api{oas}{paths}{$api{Documentation}{url}} = $api{Documentation};

    $api{url}                = $ENV{'PATH_INFO'};
    $api{url}                =~ s/\?oas//;             # For the api only romove possible parameters
    $api{url}                =~ s/\&oas//;             # For the api only romove possible parameters
    $ENV{'PATH_INFO'}        =~ s/\?oas//;             # For the api only romove possible parameters 
    $ENV{'PATH_INFO'}        =~ s/\&oas//;             # For the api only romove possible parameters 
    $api{query}              = $ENV{'QUERY_STRING'};
    $api{request_method}     = $ENV{'REQUEST_METHOD'};

    main::appdoc(\%api);
    $api{oas}{openapi}           = '3.0.3';
    
    my $t = 0;
    if (defined($api{oas}{tags})) {
         $t = scalar @{$api{oas}{tags}};
    }
    $api{oas}{tags}[ $t   ]{name}              = 'Information';
    $api{oas}{tags}[ $t++ ]{description}       = "Informational endpoints used by swagger";
    $api{oas}{tags}[ $t   ]{name}              = 'Heartbeat';
    $api{oas}{tags}[ $t++ ]{description}       = "Availability endpoinst to verify system health";
    $api{oas}{tags}[ $t   ]{name}              = 'Test';
    $api{oas}{tags}[ $t++ ]{description}       = "Test endpoints";
    $api{oas}{tags}[ $t   ]{name}              = 'Log';
    $api{oas}{tags}[ $t++ ]{description}       = "Loging interface endpoints";
    
    my $alilist = apilist();

    for (my $i = 0; $i < scalar @{$alilist}; $i++) {
        # print $alilist->[$i]{url} . "\n";
        if (($alilist->[$i]{url} ne '/')           and 
            ($alilist->[$i]{url} ne '/favicon.ico')and 
            ($alilist->[$i]{url} ne '/api')        and 
            ($alilist->[$i]{url} ne '/api/dist')   and 
            ($alilist->[$i]{url} ne '/api/doc')    and 
            ($alilist->[$i]{url} ne '/api/image')  and 
            ($alilist->[$i]{url} ne '/api/script') and 
            ($alilist->[$i]{url} ne '/api/css')    and 
            ($alilist->[$i]{url} ne '/api/explorer')) {
            
            my $method = $alilist->[$i]{method};
            if (ref $method eq 'CODE') {
                my $result = &$method($alilist->[$i], $httpreq);
                if (defined($result->{parameters})) {
                    for (my $p = 0; $p < scalar @{$result->{parameters}}; $p++) {
                        for (my $m = 0;$m < scalar @{$result->{SupportedMethod}}; $m++) {
                            if (defined($result->{parameters}[$p]{methods})) {
                                for ( my $s = 0; $s < scalar @{$result->{parameters}[$p]{methods}}; $s++) {
                                    if ($result->{parameters}[$p]{methods}[$s] eq $result->{SupportedMethod}[$m] ) {
                                        my $parameter = dclone $result->{parameters}[$p];
                                        delete $parameter->{methods};
                                        push @{$result->{lc($result->{SupportedMethod}[$m])}{parameters}}, $parameter;
                                    }
                                }
                            }
                        }
                    }
                    delete($result->{parameters});
                }
                #push @{$api{oas}{paths}}, $result->{url} => $result;
                my $url = $result->{url};
                delete $result->{url};
                delete $result->{SupportedMethod};
                $api{oas}{paths}{$url} = $result;            
            }
        }
    }

    if (defined($api{Params}{oas}) ) {
        delete $api{oas}{paths}{'/'}{SupportedMethod};
        delete $api{oas}{paths}{'/'}{url};
        delete $api{oas}{paths}{'/'};

        delete $api{oas}{paths}{'/api'}{SupportedMethod};
        delete $api{oas}{paths}{'/api'}{url};
        delete $api{oas}{paths}{'/api'};

        delete $api{oas}{paths}{'/api/doc'}{SupportedMethod};
        delete $api{oas}{paths}{'/api/doc'}{url};
        delete $api{oas}{paths}{'/api/doc'}{parameters};
        
        $api{oas}{paths}{'/api/doc'}{get}{summary}        = 'JSON documentation structure for ' . $main::SystemName;
        $api{oas}{paths}{'/api/doc'}{get}{description}    = 'Returns the json documentation description for the ' . $main::SystemName   .
                                                         ' If the &oas parameter is added to the request the structure should fit the swagger json format';
        $api{oas}{paths}{'/api/doc'}{get}{parameters}[0]{name} = 'oas';
        $api{oas}{paths}{'/api/doc'}{get}{parameters}[0]{in} = 'query';
        $api{oas}{paths}{'/api/doc'}{get}{parameters}[0]{required} = false;
        $api{oas}{paths}{'/api/doc'}{get}{parameters}[0]{schema}{type} = 'string';
        $api{oas}{paths}{'/api/doc'}{get}{parameters}[0]{allowEmptyValue} = true;
        
        $api{oas}{paths}{'/api/doc'}{get}{responses}{200}{description}  = 'OK';
        $api{oas}{paths}{'/api/doc'}{get}{responses}{200}{content}{'application/json'}{schema}{type} = 'string';
        $api{oas}{paths}{'/api/doc'}{get}{tags}        = ['Information'];
        @{$api{oas}{paths}{'/api/doc'}{get}{security}} = ();

        $api{oas}{paths}{'/api/explorer'}{get}{summary}        = 'Activates the Swagger interface for ' . $main::SystemName;
        $api{oas}{paths}{'/api/explorer'}{get}{description}    = 'Loads the Swagger interface and then loads the swagger json definition file for ' . $main::SystemName;
        $api{oas}{paths}{'/api/explorer'}{get}{responses}{200}{description}  = 'OK';
        $api{oas}{paths}{'/api/explorer'}{get}{responses}{200}{content}{'text/html'}{schema}{type} = 'string';
        $api{oas}{paths}{'/api/explorer'}{get}{tags}        = ['Information'];
        @{$api{oas}{paths}{'/api/explorer'}{get}{security}} = ();
        
    }

    print http_header(0);
    my $json = JSON::XS->new;
    $json->convert_blessed();
    if (defined($api{Params}{oas}) ) {
        print $json->encode($api{oas});
    } else {
        print $json->encode(\%api);
    }
}

sub version {
    my ($request, $httpreq) = @_;
    my %resp       = %{preInit($request, $httpreq)};
    
    $resp{Documentation}{get}{summary}     = 'Returns the ' . $main::SystemName . ' version string';
    $resp{Documentation}{get}{description} = 'Optional extended description in CommonMark or HTML';
    $resp{Documentation}{get}{responses}{200}{description}  = 'OK';
    $resp{Documentation}{get}{responses}{200}{content}{'application/json'}{schema}{type} = 'string';
    $resp{Documentation}{get}{tags}        = ['Information'];
    @{$resp{Documentation}{get}{security}} = ();

    #$resp{Documentation}{get}{responses}{401}{description}  = 'Not authenticated';
    #$resp{Documentation}{get}{responses}{403}{description}  = 'Not authorized';

    
    my $line = $resp{Line};
    allParametersUsed($line, \%resp);
    if (!defined($resp{api})) {
        #if (Authenticate(\%resp) == 1) {
            $resp{results} = \%main::version_string;
            $resp{status} = 200; 
        #} else {
        #    $resp{status} = 403 if ($resp{Authorized}    eq 'Not OK'); 
        #    $resp{status} = 401 if ($resp{Authenticated} eq 'Not OK'); 
        #}
    }
    return(finelizeRequest(\%resp));    
}


sub get_system_info{
    my $resp = shift;
    
    my %event = (
            host              => hostname(),
            fqdn              => hostfqdn(),
            'process.pid'     => $$,
    );
    return \%event
}

sub get_service_info{
    my $resp = shift;
    
    my %service = (
            name              =>  $main::SystemName,
    );
    return \%service;
}

sub get_tags{
    my $resp = shift;
    
    my %tags = (
            name              => $main::SystemName,
    );
    return \%tags;
}

sub get_trace{
    my $resp = shift;
    
    my %trace = (
            id               => $resp->{Headers}{HTTP_X_TRACE_ID}
    );
    return \%trace;
}


sub get_event_struct{
    my $resp = shift;
    
    my %event = (
            duration => tv_interval($resp->{StartTime}) ,
            kind     => "event",
            category => "web",
            type     => "access"
    );
    return \%event
}

sub get_url_struct{
    my $resp = shift;
    
    my %url = (
        "method"   => $resp->{Request}{'Request_Method'},
        "domain"   => $resp->{Request}{'server_name'},
        "path"	   => $resp->{Request}{Url},
        "query"	   => $resp->{Request}{Query},
        "function" => $resp->{Request}{Function},
        "schema"   => $resp->{Request}{schema},
    );
    return \%url;
}


sub get_http_struct{
    my $resp = shift;
    my %http = (
        "version" => '1.1',	
         "request" => {
            "method"        => $resp->{Request}{'Request_Method'},
            "schema"        => $resp->{Request}{schema},
            "mime_type"     => "",
            "bytes"         => "",
            "body_content"  => "",
        }
    );
    

    return \%http
}

sub get_http_response{
    my $resp = shift;
    my $status;

    if (defined($resp->{status_api})){  
        $status = $resp->{status_api};
    } elsif (defined($resp->{status_path})){  
        $status = $resp->{status_path};
    } else {
        $status = $resp->{status};
    }

    my %http = (
        "version" => '1.1',	
         "response" => {
            "body" =>{
                "bytes"    => $resp->{body_size},
                "content"  => dclone \%{$resp->{results}},
            },   
            "mime_type"    => "application/json",
            "status_code"  => $status,
            "timestamp"    => gclog::gctime(),
        }
    );
    
    return \%http
}

sub AddResponseDoc {
    my $resp    = shift;
    my $method  = lc(shift);
    my @include = split(/ /,shift);
    my %IncludeElement = map { $_ => 1 } @include;

    if ($IncludeElement{200}) {
        $resp->{Documentation}{$method}{responses}{200}{description}                               = 'OK';
        $resp->{Documentation}{$method}{responses}{200}{content}{'application/json'}{schema}{type} = 'string';
        $resp->{Documentation}{$method}{responses}{200}{headers}{'X-REQUEST-ID'}{description}      = 'uuid4 type id';
        $resp->{Documentation}{$method}{responses}{200}{headers}{'X-REQUEST-ID'}{schema}{type}     = 'string';
        $resp->{Documentation}{$method}{responses}{200}{headers}{'X-TRACE-ID'}{description}        = 'uuid4 type id';
        $resp->{Documentation}{$method}{responses}{200}{headers}{'X-TRACE-ID'}{schema}{type}       = 'string';
    }
         
    if ($IncludeElement{400}) {
        $resp->{Documentation}{$method}{responses}{401}{description}                               = 'Bad request';
        $resp->{Documentation}{$method}{responses}{401}{headers}{'X-TRACE-ID'}{description}        = 'uuid4 type id';
        $resp->{Documentation}{$method}{responses}{401}{headers}{'X-TRACE-ID'}{schema}{type}       = 'string';
    }
    
    if ($IncludeElement{401}) {
        $resp->{Documentation}{$method}{responses}{401}{description}                               = 'Not authenticated';
        $resp->{Documentation}{$method}{responses}{401}{headers}{'X-TRACE-ID'}{description}        = 'uuid4 type id';
        $resp->{Documentation}{$method}{responses}{401}{headers}{'X-TRACE-ID'}{schema}{type}       = 'string';
    }
         
    if ($IncludeElement{403}) {
        $resp->{Documentation}{$method}{responses}{403}{description}                               = 'Not authorized';
        $resp->{Documentation}{$method}{responses}{403}{headers}{'X-TRACE-ID'}{description}        = 'uuid4 type id';
        $resp->{Documentation}{$method}{responses}{403}{headers}{'X-TRACE-ID'}{schema}{type}       = 'string';
    }
         
    if ($IncludeElement{404}) {
        $resp->{Documentation}{$method}{responses}{404}{description}                               = 'Not content';
        $resp->{Documentation}{$method}{responses}{404}{headers}{'X-TRACE-ID'}{description}        = 'uuid4 type id';
        $resp->{Documentation}{$method}{responses}{404}{headers}{'X-TRACE-ID'}{schema}{type}       = 'string';
    }

    if ($IncludeElement{500}) {
        $resp->{Documentation}{$method}{responses}{500}{description}                               = 'Internal Error';
        $resp->{Documentation}{$method}{responses}{500}{headers}{'X-TRACE-ID'}{description}        = 'uuid4 type id';
        $resp->{Documentation}{$method}{responses}{500}{headers}{'X-TRACE-ID'}{schema}{type}       = 'string';
    }
}



1;
