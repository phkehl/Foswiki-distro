package Foswiki::Configure::Wizards::Save;

=begin TML

---++ package Foswiki::Configure::Wizards::Save

Wizard to generate LocalSite.cfg file from current $Foswiki::cfg,
taking a backup as necessary.

=cut

use strict;
use warnings;

use Foswiki::Configure::Wizard ();
our @ISA = ('Foswiki::Configure::Wizard');

use Errno;
use Fcntl;
use File::Spec                   ();
use Foswiki::Configure::Load     ();
use Foswiki::Configure::FileUtil ();

use constant STD_HEADER => <<'HERE';
# Local site settings for Foswiki. This file is managed by the 'configure'
# CGI script, though you can also make (careful!) manual changes with a
# text editor.  See the Foswiki.spec file in this directory for documentation
# Extensions are documented in the Config.spec file in the Plugins/<extension>
# or Contrib/<extension> directories  (Do not remove the following blank line.)

HERE

# Perlise a key string
sub _perlKeys {
    my $k = shift;
    $k =~ s/^{(.*)}$/$1/;
    return '{'
      . join(
        '}{', map { _perlKey($_) }
          split( /}{/, $k )
      ) . '}';
}

# Make a single key safe for use in perl
sub _perlKey {
    my $k = shift;
    return $k unless $k =~ /\W/;
    $k =~ s/'/\\'/g;
    return "'$k'";
}

sub save {
    my ( $this, $reporter ) = @_;

    # Sort keys so it's possible to diff LSC files.
    local $Data::Dumper::Sortkeys = 1;
    die "FUCK" if $Foswiki::cfg{DataDir} eq 'NOT SET';
    my ( @backups, $backup );

    my $old_content;

    my $lsc = Foswiki::Configure::FileUtil::lscFileName();

    # while loop used just so it can use 'last' :-(
    while ( -f $lsc ) {
        if ( open( F, '<', $lsc ) ) {
            local $/ = undef;
            $old_content = <F>;
            close(F);
        }
        else {
            last if ( $!{ENOENT} );    # Race: file disappeared
            die "Unable to read $lsc: $!\n";    # Serious error
        }

        unless ( defined $Foswiki::cfg{MaxLSCBackups}
            && $Foswiki::cfg{MaxLSCBackups} >= -1 )
        {
            $Foswiki::cfg{MaxLSCBackups} = 0;
            $reporter->CHANGED('{MaxLSCBackups}');
        }

        last unless ( $Foswiki::cfg{MaxLSCBackups} );

        # Save backup copy of current configuration (even if always_write)

        Fcntl->import(qw/:DEFAULT/);

        my ( $mode, $uid, $gid, $atime, $mtime ) = ( stat(_) )[ 2, 4, 5, 8, 9 ];

        # Find a reasonable starting point for the new backup's name

        my $n = 0;
        my ( $vol, $dir, $file ) = File::Spec->splitpath($lsc);
        $dir = File::Spec->catpath( $vol, $dir, 'x' );
        chop $dir;
        if ( opendir( my $d, $dir ) ) {
            @backups =
              sort { $b <=> $a }
              map { /^$file\.(\d+)$/ ? ($1) : () } readdir($d);
            my $last = $backups[0];
            $n = $last if ( defined $last );
            $n++;
            closedir($d);
        }
        else {
            $n = 1;
            unshift @backups, $n++ while ( -e "$lsc.$n" );
        }

        # Find the actual filename and open for write

        my $open;
        my $um = umask(0);
        unshift @backups, $n++
          while (
            !(
                $open = sysopen( F, "$lsc.$n",
                    O_WRONLY() | O_CREAT() | O_EXCL(), $mode & 07777
                )
            )
            && $!{EEXIST}
          );
        if ($open) {
            $backup = "$lsc.$n";
            unshift @backups, $n;
            print F $old_content;
            close(F);
            utime $atime, $mtime, $backup;
            chown $uid, $gid, $backup;
        }
        else {
            die "Unable to open $lsc.$n for write: $!\n";
        }
        umask($um);
        last;
    }

    if ( defined $old_content ) {
        local %Foswiki::cfg;
        $old_content =~ /^(.*)$/;
        eval $1;
        if ($@) {
            $reporter->ERROR("Error reading existing LocalSite.cfg: $@");
        }
        else {

            # Clean out deprecated settings, so they don't occlude the
            # replacements
            foreach my $key ( keys %Foswiki::Configure::Load::remap ) {
                $old_content =~ s/\$Foswiki::cfg$key\s*=.*?;\s*//sg;
            }
        }
    }

    unless ( defined $old_content ) {

        # Pull in a new LocalSite.cfg from the spec
        local %Foswiki::cfg = ();
        Foswiki::Configure::Load::readConfig( 1, 0, 1 );
        $old_content =
          STD_HEADER . join( '', _wordy_dump( \%Foswiki::cfg ) ) . "1;\n";
    }

    # In bootstrap mode, we want to keep the essential settings that
    # the bootstrap process worked out.
    if ( $Foswiki::cfg{isBOOTSTRAPPING} ) {
        my %save;
        foreach my $key (@Foswiki::Configure::Load::NOT_SET) {
            $save{$key} = $Foswiki::cfg{$key};
        }

        # Re-read LocalSite.cfg without expansions but with
        # the .spec
        %Foswiki::cfg = ();
        Foswiki::Configure::Load::readConfig( 1, 0, 1 );

        while ( my ( $k, $v ) = each %save ) {
            $Foswiki::cfg{$k} = $v;
        }
    }
    else {

        # Re-read LocalSite.cfg without expansions
        %Foswiki::cfg = ();
        Foswiki::Configure::Load::readConfig( 1, 1 );
    }

    # Import sets without expanding
    if ( $this->param('set') ) {
        while ( my ( $k, $v ) = each %{ $this->param('set') } ) {
            if ( defined $v && $v =~ /(.*)/ ) {
                eval "\$Foswiki::cfg" . _perlKeys($k) . "=\$1";
            }
            else {
                eval "undef \$Foswiki::cfg" . _perlKeys($k);
            }
        }
    }

    my $new_content =
      STD_HEADER . join( '', _wordy_dump( \%Foswiki::cfg ) ) . "1;\n";

    if ( $new_content ne $old_content ) {
        my $um = umask(007);   # Contains passwords, no world access to new file
        open( F, '>', $lsc )
          || die "Could not open $lsc for write: $!\n";
        print F $new_content;
        close(F) or die "Close failed for $lsc: $!\n";
        umask($um);
        if ( $backup && ( my $max = $Foswiki::cfg{MaxLSCBackups} ) >= 0 ) {
            while ( @backups > $max ) {
                my $n = pop @backups;
                unlink "$lsc.$n";
            }
            $reporter->NOTE("Previous configuration saved in $backup");
        }
        $reporter->NOTE("New configuration saved in $lsc");
    }
    else {
        unlink $backup if ($backup);
        $reporter->NOTE("No change made to $lsc");
    }
}

sub _wordy_dump {
    my ( $hash, $keys ) = @_;

    my @dump;
    if ( ref($hash) eq 'HASH' ) {
        $keys ||= '';
        foreach my $k ( sort keys %$hash ) {
            push( @dump, _wordy_dump( $hash->{$k}, $keys . "{$k}" ) );
        }
    }
    else {
        my $d = Data::Dumper->Dump( [$hash] );
        my $sk = _perlKeys($keys);
        $d =~ s/^\$VAR1/\$Foswiki::cfg$sk/;
        push( @dump, $d );
    }

    return @dump;
}

1;