package MediaWords::Solr::Query::PseudoQueries;

use strict;
use warnings;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

=head1 NAME

MediaWords::Solr::PseudoQueries - transform pseudo query clauses in Solr
queries

=head1 DESCRIPTION

Transform pseudo query clauses in Solr queries.

Pseudo queries allow us to effectively perform joins with Postgres queries
directly through the API with queries that look like:

    sentence:obama and {~ timespan:1234 }

which would be processed and replaced before sending to Solr with something
that looks like:

    sentence:obama and stories_id:( ... )

This module is integrated directly into MediaWords::Solr::Query::query_solr(),
so it shouldn't need to be called directly by the user to query Solr.

Documentation of the specific pseudo queries is in the API spec at:

    doc/api_2_0_spec/api_2_0_spec.md

=cut

use List::Compare;
use Readonly;

use MediaWords::DB;

# die if the transformed query is bigger than this
Readonly my $MAX_QUERY_LENGTH => 2_000_000;

# list of field functions that can be called within a psuedo query clause.
# the list is in [ $field_name, $field_function, $num_required_args ] format.
# for each such field in a pseudo query in field_name:arg1[-arg2 ...] format,
# the function referenced below is called on the given query, and a hash
# with at least a stories_id key is returned.  The field functions are called
# in the order listed below, and subsequent calls have access to the records
# returned by previous calls, so for example the topic_link_community
# call has access to the timespan return value to determine
# which topic timespan to mine for link community.
#
# if you add a new psuedo query field, update the pseudo query documentation in
# in the api documentation referenced in the DESCRIPTION above.
Readonly my $FIELD_FUNCTIONS => [
    [ 'controversy',                 \&_transform_topic_field,            1 ],
    [ 'topic',                       \&_transform_topic_field,            1 ],
    [ 'timespan',                    \&_transform_timespan_field,         1 ],
    [ 'controversy_dump_time_slice', \&_transform_timespan_field,         1 ],
    [ 'link_from_tag',               \&_transform_link_from_tag_field,    1 ],
    [ 'link_to_story',               \&_transform_link_to_story_field,    1 ],
    [ 'link_from_story',             \&_transform_link_from_story_field,  1 ],
    [ 'link_to_medium',              \&_transform_link_to_medium_field,   1 ],
    [ 'link_from_medium',            \&_transform_link_from_medium_field, 1 ],
];

# die with an error for the given field if there is no timespan
# field in the same query
sub _require_timespan($$)
{
    my ( $return_data, $field ) = @_;

    unless ( $return_data->{ timespan } )
    {
        die <<"EOF";
            Pseudo query error: '$field' field requires a timespan field in the
            same pseudo query clause.
EOF
    }
}

# transform link_to_story:1234 into list of stories within timespan that link
# to the given story
sub _transform_link_to_story_field($$$)
{
    my ( $db, $return_data, $to_stories_id ) = @_;

    _require_timespan( $return_data, 'link_to_story' );

    my $stories_ids = $db->query(
        <<SQL,
        SELECT source_stories_id
        FROM snapshot_story_links
        WHERE ref_stories_id = ?
SQL
        $to_stories_id
    )->flat;

    return { stories_ids => $stories_ids };
}

# transform link_from_story:1234 into list of stories within timespan that are
# linked from the given story
sub _transform_link_from_story_field($$$)
{
    my ( $db, $return_data, $from_stories_id ) = @_;

    _require_timespan( $return_data, 'link_from_story' );

    my $stories_ids = $db->query(
        <<SQL,
        SELECT ref_stories_id
        FROM snapshot_story_links
        WHERE source_stories_id = ?
SQL
        $from_stories_id
    )->flat;

    return { stories_ids => $stories_ids };
}

# transform link_to_medium:1234 into list of stories within timespan that link
# to the given medium
sub _transform_link_to_medium_field($$$)
{
    my ( $db, $return_data, $to_media_id ) = @_;

    _require_timespan( $return_data, 'link_from_medium' );

    my $stories_ids = $db->query(
        <<SQL,
        SELECT DISTINCT sl.source_stories_id
        FROM snapshot_story_links AS sl
            JOIN snapshot_stories AS s
                ON sl.ref_stories_id = s.stories_id
        WHERE s.media_id = ?
SQL
        $to_media_id
    )->flat;

    return { stories_ids => $stories_ids };
}

# transform link_from_medium:1234 into list of stories within timespan that are linked
# from the given medium
sub _transform_link_from_medium_field($$$)
{
    my ( $db, $return_data, $from_media_id ) = @_;

    _require_timespan( $return_data, 'link_from_medium' );

    my $stories_ids = $db->query(
        <<SQL,
        SELECT DISTINCT sl.ref_stories_id
        FROM snapshot_story_links AS sl
            JOIN snapshot_stories AS s
                ON sl.source_stories_id = s.stories_id
        WHERE s.media_id = ?
SQL
        $from_media_id
    )->flat;

    return { stories_ids => $stories_ids };
}

# accept topic:1234 clause and return a topic id and a list of
# stories in the live topic
sub _transform_topic_field($$$)
{
    my ( $db, $return_data, $topics_id ) = @_;

    my $stories_ids = $db->query(
        <<SQL,
        SELECT stories_id
        FROM topic_stories
        WHERE topics_id = ?
SQL
        $topics_id
    )->flat;

    return { topics_id => $topics_id, stories_ids => $stories_ids };
}

# accept timespan:1234 clause and return a timespan id and a list of
# stories_ids
sub _transform_timespan_field($$$$)
{
    my ( $db, $return_data, $timespans_id, $live ) = @_;

    my $timespan = $db->find_by_id( 'timespans', $timespans_id )
      || die( "Unable to find timespan with id '$timespans_id'" );
    my $topic = $db->query(
        <<SQL,
        SELECT DISTINCT c.*
        FROM topics AS c
            JOIN snapshots AS snap
                ON c.topics_id = snap.topics_id
        WHERE snap.snapshots_id = ?
SQL
        $timespan->{ snapshots_id }
    )->hash;

    MediaWords::TM::Snapshot::setup_temporary_snapshot_tables( $db, $timespan, $topic, $live );

    my $stories_ids = $db->query(
        <<SQL
        SELECT stories_id
        FROM snapshot_story_link_counts
SQL
    )->flat;

    return { timespans_id => $timespans_id, stories_ids => $stories_ids, live => $live };
}

# accept link_from_tag:1234[-5678] clause and return a list of stories_ids where
# the stories are those that from stories tagged with the first tags_id (either directly
# or through media) and optionally link to stories tagged with the second tags_id.  if
# the second tags_id is 'other', return stories link from the first tags_id and linking
# to any story but the given tags_id.
sub _transform_link_from_tag_field($$$$)
{
    my ( $db, $return_data, $from_tags_id, $to_tags_id ) = @_;

    $from_tags_id += 0;
    $to_tags_id   += 0;

    _require_timespan( $return_data, 'link_from_tag' );

    my $to_tags_id_clause = '';
    if ( $to_tags_id )
    {
        if ( $to_tags_id eq 'other' )
        {
            $to_tags_id_clause = <<SQL;
                AND sl.ref_stories_id NOT IN (
                    SELECT stories_id
                    FROM tagged_stories AS ts
                    WHERE ts.tags_id != $from_tags_id
                )
SQL
        }
        elsif ( $to_tags_id =~ /^\d+$/ )
        {
            $to_tags_id += 0;
            $to_tags_id_clause = <<SQL;
                AND sl.ref_stories_id IN (
                    SELECT stories_id
                    FROM tagged_stories AS ts
                    WHERE ts.tags_id = $to_tags_id
                )
SQL
        }
        else
        {
            die <<EOF
                Pseudo query error: second argument to link_field pseudo query
                clause must be an integer
EOF
        }
    }

    my $stories_ids = $db->query(
        <<"SQL"
        WITH tagged_stories AS (

            SELECT stm.stories_id, stm.tags_id
            FROM snapshot_stories_tags_map AS stm

            UNION

            SELECT s.stories_id, mtm.tags_id
            FROM snapshot_stories AS s
                JOIN media_tags_map AS mtm
                    ON s.media_id = mtm.media_id
        )

        SELECT sl.ref_stories_id
        FROM snapshot_story_links AS sl
        WHERE sl.source_stories_id IN (
            SELECT stories_id
            FROM tagged_stories AS ts
            WHERE ts.tags_id = $from_tags_id
        )
          $to_tags_id_clause
SQL
    )->flat;

    $db->commit;

    return { stories_ids => $stories_ids };
}

# given a list of $ids for $field, consolidate them into ranges where possible.
# so transform this:
#     stories_id:( 1 2 4 5 6 7 9 )
# into:
#    stories_id:( 1 2 9 ) stories_id:[ 4 TO 7 ]
sub _consolidate_id_query($$)
{
    my ( $field, $ids ) = @_;

    unless ( @{ $ids } )
    {
        die "ids list is unset";
    }

    $ids = [ sort { $a <=> $b } @{ $ids } ];

    my $singletons = [ -10 ];
    my $ranges = [ [ -10 ] ];
    for my $id ( @{ $ids } )
    {
        if ( $id == ( $ranges->[ -1 ]->[ -1 ] + 1 ) )
        {
            push( @{ $ranges->[ -1 ] }, $id );
        }
        elsif ( $id == ( $singletons->[ -1 ] + 1 ) )
        {
            push( @{ $ranges }, [ pop( @{ $singletons } ), $id ] );
        }
        else
        {
            push( @{ $singletons }, $id );
        }
    }

    shift( @{ $singletons } );
    shift( @{ $ranges } );

    my $long_ranges = [];
    for my $range ( @{ $ranges } )
    {
        if ( scalar( @{ $range } ) > 2 )
        {
            push( @{ $long_ranges }, $range );
        }
        else
        {
            push( @{ $singletons }, @{ $range } );
        }
    }

    my $queries = [];

    push( @{ $queries }, map { "$field:[$_->[ 0 ] TO $_->[ -1 ]]" } @{ $long_ranges } );
    if ( scalar( @{ $singletons } ) > 0 )
    {
        push( @{ $queries }, "$field:(" . join( ' ', @{ $singletons } ) . ')' );
    }

    my $query = join( ' ', @{ $queries } );

    return $query;
}

# accept a single {~ ... } clause and return a stories_id:(...) clause
sub _transform_clause($)
{
    my ( $clause ) = @_;

    my $db = MediaWords::DB::connect_to_db();

    $db->begin;

    # make a list of all calls to make against all field functions
    my $field_function_calls = {};
    while ( $clause =~ /(\w+):([\w-]+)/g )
    {
        my ( $field_name, $args_list ) = ( $1, $2 );

        my $args = [ split( '-', $args_list ) ];

        push( @{ $field_function_calls->{ $field_name } }, $args );
    }

    # call the field functions in the order in FIELD_FUNCTIONS and append the
    # return data to the $return_data hash
    my $return_data = {};
    my $stories_ids;
    for my $field_function ( @{ $FIELD_FUNCTIONS } )
    {
        my ( $field_name, $field_function, $num_args ) = @{ $field_function };

        if ( my $calls = $field_function_calls->{ $field_name } )
        {
            for my $call_args ( @{ $calls } )
            {
                unless ( @{ $call_args } >= $num_args )
                {
                    die <<"EOF";
                        Pseudo query error: $field_name pseudo query field
                        requires at least $num_args arguments
EOF
                }

                my $r = $field_function->( $db, $return_data, @{ $call_args } );
                push( @{ $return_data->{ $field_name } }, $r );
                if ( $r->{ stories_ids } && $stories_ids )
                {
                    my $lc = List::Compare->new(
                        {
                            lists => [ $stories_ids || [], $r->{ stories_ids } ],    #
                            unsorted => 1,                                           #
                        }
                    );
                    $stories_ids = $lc->get_intersection_ref;
                }
                elsif ( !$stories_ids )
                {
                    $stories_ids = $r->{ stories_ids };
                }
            }
        }

        delete( $field_function_calls->{ $field_name } );
    }

    $db->commit;

    if ( my @remaining_fields = keys( %{ $field_function_calls } ) )
    {
        my $str_remaining_fields = join( ", ", @remaining_fields );
        die "Pseudo query error: unknown pseudo query fields: $str_remaining_fields";
    }

    unless ( $stories_ids )
    {
        die "Pseudo query error: pseudo query fields failed to return any story ids";
    }

    if ( @{ $stories_ids } > 0 )
    {
        return _consolidate_id_query( 'stories_id', $stories_ids );
    }
    else
    {
        return 'stories_id:0';
    }
}

=head2 transform_query( $q )

Given a Solr query, transform the pseudo clauses in a query to stories_id:(...)
clauses and return the transformed Solr query.

=cut

sub transform_query($);    # prototype

sub transform_query($)
{
    my ( $q ) = @_;

    unless ( defined( $q ) )
    {
        return undef;
    }

    if ( ref( $q ) eq 'ARRAY' )
    {
        return [ map { transform_query( $_ ) } @{ $q } ];
    }

    my $t = $q;

    $t =~ s/(\{\~[^\}]*\})/_transform_clause( $1 )/eg;

    if ( length( $t ) > $MAX_QUERY_LENGTH )
    {
        die "Transformed query is longer than max of $MAX_QUERY_LENGTH";
    }

    unless ( $t eq $q )
    {
        TRACE "transformed solr query: '$q' -> '$t'";
    }

    return $t;
}

1;
