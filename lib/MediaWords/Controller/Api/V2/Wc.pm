package MediaWords::Controller::Api::V2::Wc;

use strict;
use warnings;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use MediaWords::Solr::WordCounts;

use base 'Catalyst::Controller';
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use Moose;
use namespace::autoclean;
use List::Compare;

=head1 NAME

MediaWords::Controller::Media - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

=head2 index 

=cut

BEGIN { extends 'MediaWords::Controller::Api::V2::MC_Controller_REST' }

__PACKAGE__->config( action => { list => { Does => [ qw( ~PublicApiKeyAuthenticated ~Throttled ~Logged ) ] }, } );

sub list : Local : ActionClass('MC_REST')
{
}

sub list_GET : PathPrefix( '/api' )
{
    my ( $self, $c ) = @_;

    my $sample_size = int( $c->req->params->{ sample_size } // 0 );
    if ( $sample_size > 100_000 )
    {
        $sample_size = 100_000;
    }

    my $wc = MediaWords::Solr::WordCounts->new(
        {
            num_words         => $c->req->params->{ num_words },
            sample_size       => $sample_size,
            random_seed       => $c->req->params->{ random_seed },
            ngram_seed        => $c->req->params->{ ngram_seed },
            include_stopwords => $c->req->params->{ include_stopwords },
        }
    );

    my $words = $wc->get_words( $c->dbis, $c->req->params->{ q }, $c->req->params->{ fq } );

    unless ( int( $c->req->params->{ include_stats } // 0 ) )
    {
        $words = $words->{ words };
    }

    $self->status_ok( $c, entity => $words );
}

1;
