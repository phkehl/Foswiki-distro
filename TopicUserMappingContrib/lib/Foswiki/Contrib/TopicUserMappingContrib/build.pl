#!/usr/bin/env perl
use strict;
use warnings;

BEGIN {
    unshift @INC, split( /:/, $ENV{FOSWIKI_LIBS} );
}
use Foswiki::Contrib::Build;

# Create the build object
my $build = new Foswiki::Contrib::Build('TopicUserMappingContrib');

# (Optional) Set the details of the repository for uploads.
# This can be any web on any accessible Wiki installation.
# These defaults will be used when expanding tokens in .txt
# files, but be warned, they can be overridden at upload time!

# Build the target on the command line, or the default target
$build->build( $build->{target} );

