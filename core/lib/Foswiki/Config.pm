# See bottom of file for license and copyright information

package Foswiki::Config;
use v5.14;

use Assert;
use Encode;
use File::Basename;
use File::Spec;
use POSIX qw(locale_h);
use Unicode::Normalize;
use Cwd qw( abs_path );
use Try::Tiny;
use Foswiki ();

use Moo;
use namespace::clean;
extends qw(Foswiki::AppObject);

# Enable to trace auto-configuration (Bootstrap)
use constant TRAUTO => 1;

# This should be the one place in Foswiki that knows the syntax of valid
# configuration item keys. Only simple scalar hash keys are supported.
#
my $ITEMREGEX = qr/(?:\{(?:'(?:\\.|[^'])+'|"(?:\\.|[^"])+"|[A-Za-z0-9_]+)\})+/;

# Generic booleans, used in some older LSC's
our $TRUE  = 1;
our $FALSE = 0;

# Configuration items that have been deprecated and must be mapped to
# new configuration items. The value is mapped unchanged.
my %remap = (
    '{StoreImpl}'           => '{Store}{Implementation}',
    '{AutoAttachPubFiles}'  => '{RCS}{AutoAttachPubFiles}',
    '{QueryAlgorithm}'      => '{Store}{QueryAlgorithm}',
    '{SearchAlgorithm}'     => '{Store}{SearchAlgorithm}',
    '{Site}{CharSet}'       => '{Store}{Encoding}',
    '{RCS}{FgrepCmd}'       => '{Store}{FgrepCmd}',
    '{RCS}{EgrepCmd}'       => '{Store}{EgrepCmd}',
    '{RCS}{overrideUmask}'  => '{Store}{overrideUmask}',
    '{RCS}{dirPermission}'  => '{Store}{dirPermission}',
    '{RCS}{filePermission}' => '{Store}{filePermission}',
    '{RCS}{WorkAreaDir}'    => '{Store}{WorkAreaDir}'
);

has data => (
    is      => 'rw',
    lazy    => 1,
    clearer => 1,
    default => sub { {} },
);

# What files we read the config from in the order of reading.
has files => (
    is      => 'rw',
    default => sub { [] },
);

# failed keeps the name of the failed config or spec file.
has failedConfig     => ( is => 'rw', );
has bootstrapMessage => ( is => 'rw', );
has noExpand         => ( is => 'rw', default => 0, );
has noSpec           => ( is => 'rw', default => 0, );
has configSpec       => ( is => 'rw', default => 0, );
has noLocal          => ( is => 'rw', default => 0, );

=begin TML

---++ ClassMethod new([noExpand => 0/1][, noSpec => 0/1][, configSpec => 0/1][, noLoad => 0/1])
   
   * =noExpand= - suppress expansion of $Foswiki vars embedded in
     values.
   * =noSpec= - can be set when the caller knows that Foswiki.spec
     has already been read.
   * =configSpec= - if set, will also read Config.spec files located
     using the standard methods (iff !$nospec). Slow.
   * =noLocal= - if set, Load will not re-read an existing LocalSite.cfg.
     this is needed when testing the bootstrap.  If it rereads an existing
     config, it overlays all the bootstrapped settings.
=cut

sub BUILD {
    my $this = shift;
    my ($params) = @_;

    # Alias ::cfg for compatibility. Though $app->cfg should be preferred way of
    # accessing config.
    *Foswiki::cfg = $this->data;
    *TWiki::cfg   = $this->data;

    $this->data->{isVALID} =
      $this->readConfig( $this->noExpand, $this->noSpec, $this->configSpec,
        $this->noLocal, );

    $this->_populatePresets;
}

sub _workOutOS {
    my $this = shift;
    unless ( $this->data->{DetailedOS} ) {
        $this->data->{DetailedOS} = $^O;
    }
    return if $this->data->{OS};
    if ( $this->data->{DetailedOS} =~ m/darwin/i ) {    # MacOS X
        $this->data->{OS} = 'UNIX';
    }
    elsif ( $this->data->{DetailedOS} =~ m/Win/i ) {
        $this->data->{OS} = 'WINDOWS';
    }
    elsif ( $this->data->{DetailedOS} =~ m/vms/i ) {
        $this->data->{OS} = 'VMS';
    }
    elsif ( $this->data->{DetailedOS} =~ m/bsdos/i ) {
        $this->data->{OS} = 'UNIX';
    }
    elsif ( $this->data->{DetailedOS} =~ m/solaris/i ) {
        $this->data->{OS} = 'UNIX';
    }
    elsif ( $this->data->{DetailedOS} =~ m/dos/i ) {
        $this->data->{OS} = 'DOS';
    }
    elsif ( $this->data->{DetailedOS} =~ m/^MacOS$/i ) {

        # MacOS 9 or earlier
        $this->data->{OS} = 'MACINTOSH';
    }
    elsif ( $this->data->{DetailedOS} =~ m/os2/i ) {
        $this->data->{OS} = 'OS2';
    }
    else {

        # Erm.....
        $this->data->{OS} = 'UNIX';
    }
}

=begin TML

---++ ObjectMethod readConfig

In normal Foswiki operations as a web server this method is called by the
=BEGIN= block of =Foswiki.pm=.  However, when benchmarking/debugging it can be
replaced by custom code which sets the configuration hash.  To prevent us from
overriding the custom code again, we use an "unconfigurable" key
=$cfg{ConfigurationFinished}= as an indicator.

Note that this method is called by Foswiki and configure, and normally reads
=Foswiki.spec= to get defaults. Other spec files (those for extensions) are
*not* read unless the $config_spec flag is set.

The assumption is that =configure= will be run when an extension is installed,
and that will add the config values to LocalSite.cfg, so no defaults are
needed. Foswiki.spec is still read because so much of the core code doesn't
provide defaults, and it would be silly to have them in two places anyway.
=cut

sub readConfig {
    my $this = shift;
    my ( $noExpand, $noSpec, $configSpec, $noLocal ) = @_;

    # To prevent us from overriding the custom code in test mode
    return 1 if $this->data->{ConfigurationFinished};

    # Assume LocalSite.cfg is valid - will be set false if errors detected.
    my $validLSC = 1;

    # Read Foswiki.spec and LocalSite.cfg
    # (Suppress Foswiki.spec if already read)

    # Old configs might not bootstrap the OS settings, so set if needed.
    $this->_workOutOS unless ( $this->data->{OS} && $this->data->{DetailedOS} );

    unless ($noSpec) {
        push @{ $this->files }, 'Foswiki.spec';
    }
    if ( !$noSpec && $configSpec ) {
        foreach my $dir (@INC) {
            foreach my $subdir ( 'Foswiki/Plugins', 'Foswiki/Contrib' ) {
                my $d;
                next unless opendir( $d, "$dir/$subdir" );
                my %read;
                foreach
                  my $extension ( grep { !/^\./ && !/^Empty/ } readdir $d )
                {
                    next if $read{$extension};
                    $extension =~ m/(.*)/;    # untaint
                    my $file = "$dir/$subdir/$1/Config.spec";
                    next unless -e $file;
                    push( @{ $this->files }, $file );
                    $read{$extension} = 1;
                }
                closedir($d);
            }
        }
    }
    unless ($noLocal) {
        push @{ $this->files }, 'LocalSite.cfg';
    }

    for my $file ( @{ $this->files } ) {
        my $return = do $file;

        unless ( defined $return && $return eq '1' ) {

            my $errorMessage;
            if ($@) {
                $errorMessage = "Failed to parse $file: $@";
                warn "couldn't parse $file: $@" if $@;
            }
            next if ( !DEBUG && ( $file =~ m/Config\.spec$/ ) );
            if ( not defined $return ) {
                unless ( $! == 2 && $file eq 'LocalSite.cfg' ) {

                    # LocalSite.cfg doesn't exist, which is OK
                    warn "couldn't do $file: $!";
                    $errorMessage = "Could not do $file: $!";
                }
                $this->failedConfig($file);
                $validLSC = 0;
            }

            # Pointless (says CDot), Config.spec does not need 1; at the end
            #elsif ( not $return eq '1' ) {
            #   print STDERR
            #   "Running file $file returned  unexpected results: $return \n";
            #}
            if ($errorMessage) {

                # SMELL die has to be replaced with an exception.
                die <<GOLLYGOSH;
Content-type: text/plain

$errorMessage
Please inform the site admin.
GOLLYGOSH
                exit 1;
            }
        }
    }

    # Patch deprecated config settings
    # TODO: remove this in version 2.0
    if ( exists $this->data->{StoreImpl} ) {
        $this->data->{Store}{Implementation} =
          'Foswiki::Store::' . $this->data->{StoreImpl};
        delete $this->data->{StoreImpl};
    }
    foreach my $el ( keys %remap ) {

        # Only remap if the old key extsts, and the new key does NOT exist
        if ( ( eval("exists \$this->data->$el") ) ) {
            eval( <<CODE );
\$this->data->$remap{$el}=\$this->data->$el unless ( exists \$this->data->$remap{$el} );
delete \$this->data->$el;
CODE
            print STDERR "REMAP failed $@" if ($@);
        }
    }

    # Expand references to $this->data vars embedded in the values of
    # other $this->data vars.
    $this->expandValue( $this->data ) unless $noExpand;

    $this->data->{ConfigurationFinished} = 1;

    if ( $^O eq 'MSWin32' ) {

        #force paths to use '/'
        $this->data->{PubDir}      =~ s|\\|/|g;
        $this->data->{DataDir}     =~ s|\\|/|g;
        $this->data->{ToolsDir}    =~ s|\\|/|g;
        $this->data->{ScriptDir}   =~ s|\\|/|g;
        $this->data->{TemplateDir} =~ s|\\|/|g;
        $this->data->{LocalesDir}  =~ s|\\|/|g;
        $this->data->{WorkingDir}  =~ s|\\|/|g;
    }

    # Add explicit {Site}{CharSet} for older extensions. Default to utf-8.
    # Explanation is in http://foswiki.org/Tasks/Item13435
    $this->data->{Site}{CharSet} = 'utf-8';

    # Explicit return true if we've completed the load
    return $validLSC;
}

=begin TML

---++ ObjectMethod expandValue($datum [, $mode])

Expands references to Foswiki configuration items which occur in the
values configuration items contained within the datum, which may be a
hash or array reference, or a scalar value. The replacement is done in-place.

$mode - How to handle undefined values:
   * false:  'undef' (string) is returned when an undefined value is
     encountered.
   * 1 : return undef if any undefined value is encountered.
   * 2 : return  '' for any undefined value (including embedded)
   * 3 : die if an undefined value is encountered.

=cut

sub expandValue {
    my $this = shift;
    my $undef;
    $this->_expandValue( $_[0], ( $_[1] || 0 ), $undef );

    $_[0] = undef if ($undef);
}

# $_[0] - value being expanded
# $_[1] - $mode
# $_[2] - $undef (return)
sub _expandValue {
    my $this = shift;
    if ( ref( $_[0] ) eq 'HASH' ) {
        $this->expandValue( $_, $_[1] ) foreach ( values %{ $_[0] } );
    }
    elsif ( ref( $_[0] ) eq 'ARRAY' ) {
        $this->expandValue( $_, $_[1] ) foreach ( @{ $_[0] } );

        # Can't do this, because Windows uses an object (Regexp) for regular
        # expressions.
        #    } elsif (ref($_[0])) {
        #        die("Can't handle a ".ref($_[0]));
    }
    else {
        1 while ( defined( $_[0] )
            && $_[0] =~
            s/(\$Foswiki::cfg$ITEMREGEX)/_handleExpand($this, $1, @_[1,2])/ges
        );
    }
}

# Used to expand the $Foswiki::cfg variable in the expand* routines.
# $_[0] - $item
# $_[1] - $mode
# $_[2] - $undef
sub _handleExpand {
    my $this = shift;
    my $val  = eval( $_[0] );
    Foswiki::Exception::Fatal->throw( text => "Error expanding $_[0]: $@" )
      if ($@);

    return $val                                      if ( defined $val );
    return 'undef'                                   if ( !$_[1] );
    return ''                                        if ( $_[1] == 2 );
    die "Undefined value in expanded string $_[0]\n" if ( $_[1] == 3 );
    $_[2] = 1;
    return '';
}

=begin TML
---++ ObjectMethod bootstrap()

This method tries to determine mandatory configuration defaults to operate
when no LocalSite.cfg is found.

=cut

sub bootstrap {
    my $this = shift;

    # Strip off any occasional configuration data which might be a result of
    # previously failed readConfig.
    $this->clear_data;

    my $env = $this->app->env;

    print STDERR "AUTOCONFIG: Bootstrap Phase 1: " . Data::Dumper::Dumper($env)
      if (TRAUTO);

    # Try to create $Foswiki::cfg in a minimal configuration,
    # using paths and URLs relative to this request. If URL
    # rewriting is happening in the web server this is likely
    # to go down in flames, but it gives us the best chance of
    # recovering. We need to guess values for all the vars that

    # would trigger "undefined" errors
    my $bin;
    my $script = '';
    if ( defined $env->{FOSWIKI_SCRIPTS} ) {
        $bin = $env->{FOSWIKI_SCRIPTS};
    }
    else {
        eval('require FindBin');
        Foswiki::Exception::Fatal->throw( text =>
              "Could not load FindBin to support configuration recovery: $@" )
          if $@;
        FindBin::again();    # in case we are under mod_perl or similar
        $FindBin::Bin =~ m/^(.*)$/;
        $bin = $1;
        $FindBin::Script =~ m/^(.*)$/;
        $script = $1;
    }

    # Can't use Foswiki::decode_utf8 - this is too early in initialization
    # SMELL TODO The above must not be true anymore. Yet, why not use
    # Encode::decode_utf8?
    print STDERR "AUTOCONFIG: Found Bin dir: "
      . $bin
      . ", Script name: $script using FindBin\n"
      if (TRAUTO);

    $this->data->{ScriptSuffix} = ( fileparse( $script, qr/\.[^.]*/ ) )[2];
    $this->data->{ScriptSuffix} = ''
      if ( $this->data->{ScriptSuffix} eq '.fcgi' );
    print STDERR "AUTOCONFIG: Found SCRIPT SUFFIX "
      . $this->data->{ScriptSuffix} . "\n"
      if ( TRAUTO && $this->data->{ScriptSuffix} );

    my %rel_to_root = (
        DataDir    => { dir => 'data',   required => 0 },
        LocalesDir => { dir => 'locale', required => 0 },
        PubDir     => { dir => 'pub',    required => 0 },
        ToolsDir   => { dir => 'tools',  required => 0 },
        WorkingDir => {
            dir           => 'working',
            required      => 1,
            validate_file => 'README'
        },
        TemplateDir => {
            dir           => 'templates',
            required      => 1,
            validate_file => 'foswiki.tmpl'
        },
        ScriptDir => {
            dir           => 'bin',
            required      => 1,
            validate_file => 'setlib.cfg'
        }
    );

    # Note that we don't resolve x/../y to y, as this might
    # confuse soft links
    my $root = File::Spec->catdir( $bin, File::Spec->updir() );
    $root =~ s{\\}{/}g;
    my $fatal = '';
    my $warn  = '';
    while ( my ( $key, $def ) = each %rel_to_root ) {
        $this->data->{$key} = File::Spec->rel2abs( $def->{dir}, $root );
        $this->data->{$key} = abs_path( $this->data->{$key} );
        ( $this->data->{$key} ) = $this->data->{$key} =~ m/^(.*)$/;    # untaint

        # Need to decode utf8 back to perl characters.  The file path operations
        # all worked with bytes, but Foswiki needs characters.
        $this->data->{$key} = NFC( Encode::decode_utf8( $this->data->{$key} ) );

        print STDERR "AUTOCONFIG: $key = "
          . Encode::encode_utf8( $this->data->{$key} ) . "\n"
          if (TRAUTO);

        if ( -d $this->data->{$key} ) {
            if ( $def->{validate_file}
                && !-e $this->data->{$key} . "/$def->{validate_file}" )
            {
                $fatal .=
                    "\n{$key} (guessed "
                  . $this->data->{$key} . ") "
                  . $this->data->{$key}
                  . "/$def->{validate_file} not found";
            }
        }
        elsif ( $def->{required} ) {
            $fatal .= "\n{$key} (guessed " . $this->data->{$key} . ")";
        }
        else {
            $warn .=
              "\n      * Note: {$key} could not be guessed. Set it manually!";
        }
    }

    # Bootstrap the Site Locale and CharSet
    $this->_bootstrapSiteSettings();

    # Bootstrap the store related settings.
    $this->_bootstrapStoreSettings();

    if ($fatal) {
        Foswiki::Exception::Fatal->throw( text => <<EPITAPH );
Unable to bootstrap configuration. LocalSite.cfg could not be loaded,
and Foswiki was unable to guess the locations of the following critical
directories: $fatal
EPITAPH
    }

# Re-read Foswiki.spec *and Config.spec*. We need the Config.spec's
# to get a true picture of our defaults (notably those from
# JQueryPlugin. Without the Config.spec, no plugins get registered)
# Don't load LocalSite.cfg if it exists (should normally not exist when bootstrapping)
    $this->readConfig( 0, 0, 1, 1 );

    $this->_workOutOS();
    print STDERR "AUTOCONFIG: Detected OS "
      . $this->data->{OS}
      . ":  DetailedOS: "
      . $this->data->{DetailedOS} . " \n"
      if (TRAUTO);

    $this->data->{isVALID} = 1;
    $this->setBootstrap();

    # Note: message is not I18N'd because there is no point; there
    # is no localisation in a default cfg derived from Foswiki.spec
    my $system_message = <<BOOTS;
*WARNING !LocalSite.cfg could not be found* (This is normal for a new installation) %BR%
This Foswiki is running using a bootstrap configuration worked
out by detecting the layout of the installation.
BOOTS

    if ($warn) {
        chomp $system_message;
        $system_message .= $warn . "\n";
    }
    $this->bootstrapMessage( $system_message // '' );
}

=begin TML

---++ ObjectMethod _bootstrapSiteSettings()

Called by bootstrapConfig.  This handles the {Site} settings.

=cut

sub _bootstrapSiteSettings {
    my $this = shift;

#   Guess a locale first.   This isn't necessarily used, but helps guess a CharSet, which is always used.

    require locale;
    $this->data->{Site}{Locale} = setlocale(LC_CTYPE);

    print STDERR "AUTOCONFIG: Set initial {Site}{Locale} to  "
      . $this->data->{Site}{Locale} . "\n";
}

=begin TML

---++ ObjectMethod _bootstrapStoreSettings()

Called by bootstrapConfig.  This handles the store specific settings.   This in turn
tests each Store Contib to determine if it's capable of bootstrapping.

=cut

sub _bootstrapStoreSettings {
    my $this = shift;

    # Ask each installed store to bootstrap itself.

    my @stores = Foswiki::Configure::FileUtil::findPackages(
        'Foswiki::Contrib::*StoreContrib');

    foreach my $store (@stores) {
        try {
            Foswiki::load_package($store);
        }
        finally {
            unless (@_) {
                my $ok;
                eval('$ok = $store->can(\'bootstrapStore\')');
                if ($@) {
                    print STDERR $@;
                }
                else {
                    $store->bootstrapStore() if ($ok);
                }
            }
        };
    }

    # Handle the common store settings managed by Core.  Important ones
    # guessed/checked here include:
    #  - $Foswiki::cfg{Store}{SearchAlgorithm}

    # Set PurePerl search on Windows, or FastCGI systems.
    if (
        (
               $this->data->{Engine}
            && $this->data->{Engine} =~ m/(FastCGI|Apache)/
        )
        || $^O eq 'MSWin32'
      )
    {
        $this->data->{Store}{SearchAlgorithm} =
          'Foswiki::Store::SearchAlgorithms::PurePerl';
        print STDERR
"AUTOCONFIG: Detected FastCGI, mod_perl or MS Windows. {Store}{SearchAlgorithm} set to PurePerl\n"
          if (TRAUTO);
    }
    else {

        # SMELL: The fork to `grep goes into a loop in the unit tests
        # Not sure why, for now just default to pure perl bootstrapping
        # in the unit tests.
        if ( !$Foswiki::inUnitTestMode ) {

            # Untaint PATH so we can check for grep on the path
            my $x = $ENV{PATH} || '';
            $x =~ m/^(.*)$/;
            $ENV{PATH} = $1;
            `grep -V 2>&1`;
            if ($!) {
                print STDERR
"AUTOCONFIG: Unable to find a valid 'grep' on the path. Forcing PurePerl search\n"
                  if (TRAUTO);
                $this->data->{Store}{SearchAlgorithm} =
                  'Foswiki::Store::SearchAlgorithms::PurePerl';
            }
            else {
                $this->data->{Store}{SearchAlgorithm} =
                  'Foswiki::Store::SearchAlgorithms::Forking';
                print STDERR
                  "AUTOCONFIG: {Store}{SearchAlgorithm} set to Forking\n"
                  if (TRAUTO);
            }
            $ENV{PATH} = $x;    # re-taint
        }
        else {
            $this->data->{Store}{SearchAlgorithm} =
              'Foswiki::Store::SearchAlgorithms::PurePerl';
        }
    }

    # Detect the NFC / NDF normalization of the file system, and set
    # NFCNormalizeFilenames if needed.
    # SMELL: Really this should be done per web, both in data and pub.
    my $nfcok =
      Foswiki::Configure::FileUtil::canNfcFilenames( $Foswiki::cfg{DataDir} );
    if ( defined $nfcok && $nfcok == 1 ) {
        print STDERR "AUTOCONFIG: Data Storage allows NFC filenames\n"
          if (TRAUTO);
        $this->data->{NFCNormalizeFilenames} = 0;
    }
    elsif ( defined($nfcok) && $nfcok == 0 ) {
        print STDERR "AUTOCONFIG: Data Storage enforces NFD filenames\n"
          if (TRAUTO);
        $this->data->{NFCNormalizeFilenames} = 1
          ; #the configure's interface still shows unchecked - so, don't understand.. ;(
    }
    else {
        print STDERR "AUTOCONFIG: WARNING: Unable to detect Normalization.\n";
        $this->data->{NFCNormalizeFilenames} = 1;    #enable too - safer as none
    }
}

=begin TML

---++ ObjectMethod setBootstrap()

This routine is called to initialize the bootstrap process.   It sets the list of
configuration parameters that will need to be set and "protected" during bootstrap.

If any keys will be set during bootstrap / initial creation of LocalSite.cfg, they
should be added here so that they are preserved when the %Foswiki::cfg hash is
wiped and re-initialized from the Foswiki spec.

=cut

sub setBootstrap {
    my $this = shift;

    # Bootstrap works out the correct values of these keys
    my @BOOTSTRAP =
      qw( {DataDir} {DefaultUrlHost} {DetailedOS} {OS} {PubUrlPath} {ToolsDir} {WorkingDir}
      {PubDir} {TemplateDir} {ScriptDir} {ScriptUrlPath} {ScriptUrlPaths}{view}
      {ScriptSuffix} {LocalesDir} {Store}{Implementation} {NFCNormalizeFilenames}
      {Store}{SearchAlgorithm} {Site}{Locale} );

    $this->data->{isBOOTSTRAPPING} = 1;
    push( @{ $this->data->{BOOTSTRAP} }, @BOOTSTRAP );
}

# Preset values that are hard-coded and not coming from external sources.
sub _populatePresets {
    my $this = shift;

    $this->data->{SwitchBoard} //= {};

    # package - perl package that contains the method for this request
    # function - name of the function in package
    # context - hash of context vars to define
    # allow - hash of HTTP methods to allow (all others are denied)
    # deny - hash of HTTP methods that are denied (all others are allowed)
    # 'deny' is not tested if 'allow' is defined

    # The switchboard can contain entries either as hashes or as arrays.
    # The array format specifies [0] package, [1] function, [2] context
    # and should be used when declaring scripts from plugins that must work
    # with Foswiki 1.0.0 and 1.0.4.

    $this->data->{SwitchBoard}{attach} = {
        package  => 'Foswiki::UI::Attach',
        function => 'attach',
        context  => { attach => 1 },
    };
    $this->data->{SwitchBoard}{changes} = {
        package  => 'Foswiki::UI::Changes',
        function => 'changes',
        context  => { changes => 1 },
    };
    $this->data->{SwitchBoard}{configure} = {
        package  => 'Foswiki::UI::Configure',
        function => 'configure'
    };
    $this->data->{SwitchBoard}{edit} = {
        package  => 'Foswiki::UI::Edit',
        function => 'edit',
        context  => { edit => 1 },
    };
    $this->data->{SwitchBoard}{jsonrpc} = {
        package  => 'Foswiki::Contrib::JsonRpcContrib',
        function => 'dispatch',
        context  => { jsonrpc => 1 },
    };
    $this->data->{SwitchBoard}{login} = {
        package  => undef,
        function => 'logon',
        context  => { ( login => 1, logon => 1 ) },
    };
    $this->data->{SwitchBoard}{logon} = {
        package  => undef,
        function => 'logon',
        context  => { ( login => 1, logon => 1 ) },
    };
    $this->data->{SwitchBoard}{manage} = {
        package  => 'Foswiki::UI::Manage',
        function => 'manage',
        context  => { manage => 1 },
        allow    => { POST => 1 },
    };
    $this->data->{SwitchBoard}{oops} = {
        package  => 'Foswiki::UI::Oops',
        function => 'oops_cgi',
        context  => { oops => 1 },
    };
    $this->data->{SwitchBoard}{preview} = {
        package  => 'Foswiki::UI::Preview',
        function => 'preview',
        context  => { preview => 1 },
    };
    $this->data->{SwitchBoard}{previewauth} =
      $this->data->{SwitchBoard}{preview};
    $this->data->{SwitchBoard}{rdiff} = {
        package  => 'Foswiki::UI::RDiff',
        function => 'diff',
        context  => { diff => 1 },
    };
    $this->data->{SwitchBoard}{rdiffauth} = $this->data->{SwitchBoard}{rdiff};
    $this->data->{SwitchBoard}{register}  = {
        package  => 'Foswiki::UI::Register',
        function => 'register_cgi',
        context  => { register => 1 },

        # method verify must allow GET; protect in Foswiki::UI::Register
        #allow => { POST => 1 },
    };
    $this->data->{SwitchBoard}{rename} = {
        package  => 'Foswiki::UI::Rename',
        function => 'rename',
        context  => { rename => 1 },

        # Rename is 2 stage; protect in Foswiki::UI::Rename
        #allow => { POST => 1 },
    };
    $this->data->{SwitchBoard}{resetpasswd} = {
        package  => 'Foswiki::UI::Passwords',
        function => 'resetPassword',
        context  => { resetpasswd => 1 },
        allow    => { POST => 1 },
    };
    $this->data->{SwitchBoard}{rest} = {
        package  => 'Foswiki::UI::Rest',
        function => 'rest',
        context  => { rest => 1 },
    };
    $this->data->{SwitchBoard}{restauth} = $this->data->{SwitchBoard}{rest};
    $this->data->{SwitchBoard}{save}     = {
        package  => 'Foswiki::UI::Save',
        function => 'save',
        context  => { save => 1 },
        allow    => { POST => 1 },
    };
    $this->data->{SwitchBoard}{search} = {
        package  => 'Foswiki::UI::Search',
        function => 'search',
        context  => { search => 1 },
    };
    $this->data->{SwitchBoard}{statistics} = {
        package  => 'Foswiki::UI::Statistics',
        function => 'statistics',
        context  => { statistics => 1 },
    };
    $this->data->{SwitchBoard}{upload} = {
        package  => 'Foswiki::UI::Upload',
        function => 'upload',
        context  => { upload => 1 },
        allow    => { POST => 1 },
    };
    $this->data->{SwitchBoard}{viewfile} = {
        package  => 'Foswiki::UI::Viewfile',
        function => 'viewfile',
        context  => { viewfile => 1 },
    };
    $this->data->{SwitchBoard}{viewfileauth} =
      $this->data->{SwitchBoard}{viewfile};
    $this->data->{SwitchBoard}{view} = {
        package  => 'Foswiki::UI::View',
        function => 'view',
        context  => { view => 1 },
    };
    $this->data->{SwitchBoard}{viewauth} = $this->data->{SwitchBoard}{view};
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2008-2015 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

Additional copyrights apply to some or all of the code in this
file as follows:

Copyright (C) 1999-2006 TWiki Contributors. All Rights Reserved.
TWiki Contributors are listed in the AUTHORS file in the root of
this distribution. NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
