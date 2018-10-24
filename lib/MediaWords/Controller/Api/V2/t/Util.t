use strict;
use warnings;

use Modern::Perl '2015';
use MediaWords::CommonLibs;

use Test::More;
use Test::Deep;

use MediaWords::Test::API;
use MediaWords::Test::DB;

sub test_is_syndicated_ap($)
{
    my ( $db ) = @_;

    my $label = "stories/is_syndicated_ap";

    my $r = MediaWords::Test::API::test_put( '/api/v2/util/is_syndicated_ap', { content => 'foo' } );
    is( $r->{ is_syndicated }, 0, "$label: not syndicated" );

    $r = MediaWords::Test::API::test_put( '/api/v2/util/is_syndicated_ap', { content => '(ap)' } );
    is( $r->{ is_syndicated }, 1, "$label: syndicated" );

}

sub test_util($)
{
    my ( $db ) = @_;

    MediaWords::Test::API::setup_test_api_key( $db );

    test_is_syndicated_ap( $db );
}

sub main
{
    MediaWords::Test::DB::test_on_test_database( \&test_util );

    done_testing();
}

main();
