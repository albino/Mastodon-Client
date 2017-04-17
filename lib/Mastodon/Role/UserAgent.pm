package Mastodon::Role::UserAgent;

our $VERSION = '0';

use v5.10.0;
use Moo::Role;

use Log::Any;
my $log = Log::Any->get_logger( category => 'Mastodon' );

use URI::QueryParam;
use List::Util qw( any );
use Types::Standard qw( Undef Str Num ArrayRef HashRef Dict slurpy );
use Mastodon::Types qw( URI Instance UserAgent );
use Type::Params qw( compile );
use Carp;

has instance => (
  is => 'rw',
  isa => Instance,
  default => 'https://mastodon.social',
  coerce => 1,
);

has api_version => (
  is => 'ro',
  isa => Num,
  default => 1,
);

has redirect_uri => (
  is => 'ro',
  isa => Str,
  lazy => 1,
  default => 'urn:ietf:wg:oauth:2.0:oob',
);

has user_agent => (
  is => 'ro',
  isa => UserAgent,
  default => sub {
    require LWP::UserAgent;
    LWP::UserAgent->new;
  },
);

sub authorization_url {
  my $self = shift;

  unless ($self->client_id and $self->client_secret) {
    croak $log->fatal(
      'Cannot get authorization URL without client_id and client_secret'
    );
  }

  state $check = compile( slurpy Dict[
    instance => Instance->plus_coercions( Undef, sub { $self->instance } ),
  ]);

  use URI::QueryParam;
  my ($params) = $check->(@_);
  my $uri = URI->new('/oauth/authorize')->abs($params->{instance}->uri);
  $uri->query_param(redirect_uri => $self->redirect_uri);
  $uri->query_param(response_type => 'code');
  $uri->query_param(client_id => $self->client_id);
  $uri->query_param(scope => join ' ', sort(@{$self->scopes}));
  return $uri;
}

sub post   { shift->_request( post   => shift, data   => shift, @_ ) }
sub patch  { shift->_request( patch  => shift, data   => shift, @_ ) }
sub get    { shift->_request( get    => shift, params => shift, @_ ) }
sub delete { shift->_request( delete => shift, params => shift, @_ ) }

sub _build_url {
  my $self = shift;

  state $check = compile(
    URI->plus_coercions(
      Str, sub {
        s%(^/|/$)%%g;
        require URI;
        my $api = (m%^/?oauth/%) ? '' : 'api/v' . $self->api_version . '/';
        URI->new(join '/', $self->instance->uri, $api . $_);
      },
    )
  );

  my ($url) = $check->(@_);
  return $url;
}

sub _request {
  my $self   = shift;
  my $method = shift;
  my $url    = shift;
  my $args   = { @_ };

  $url = $self->_build_url($url) unless ref $url eq 'URI';

  my $data    = $args->{data}    // {};
  my $headers = $args->{headers} // {};
  my $params  = $args->{params}  // {};

  $method = uc($method);

  if ($self->can('access_token') and $self->access_token) {
    $headers = {
      Authorization => 'Bearer ' . $self->access_token,
      %{$headers},
    };
  }

  # Adjust query param format to be Ruby-compliant
  foreach my $key (keys %{$params}) {
    my $val = $params->{$key};
    if (ref $val eq 'ARRAY') { $url->query_param($key . '[]' => @{$val}) }
    else                     { $url->query_param($key => $val) }
  }

  foreach my $key (keys %{$data}) {
    # Array parameters to the API need keys that are marked with []
    # However, HTTP::Request::Common expects an arrayref to encode files
    # for transfer, even though the API does not expect that to be an array
    # So we need to manually skip it, unless we come up with another solution.
    next if $key eq 'file';

    my $val = $data->{$key};
    $data->{$key . '[]'} = delete($data->{$key}) if ref $val eq 'ARRAY';
  }

  if ($log->is_trace) {
    require Data::Dumper;
    $log->debugf('Method:  %s', $method);
    $log->debugf('URL: %s', $url);
    $log->debugf('Headers: %s', Data::Dumper::Dumper( $headers ));
    $log->debugf('Data:    %s', Data::Dumper::Dumper( $data ));
  }

  use Try::Tiny;
  return try {
    my @args = $url;
    push @args, [%{$data}] unless $method eq 'GET';
    @args = (@args, %{$headers});

    require HTTP::Request::Common;
    my $type = ($method eq 'PATCH') ? 'POST' : $method;
    my $request = HTTP::Request::Common->can($type)->( @args );
    $request->method($method);

    my $response = $self->user_agent->request( $request );

    require JSON;
    require Encode;

    die $response->status_line unless $response->is_success;

    my $data = JSON::decode_json(
      Encode::encode('utf8', $response->decoded_content)
    );

    # Some API calls return empty objects, which cannot be coerced
    if ($response->decoded_content ne '{}') {
      if ($url !~ /oauth/ and $self->coerce_entities) {
        use Mastodon::Types qw( to_Entity );
        $data = (ref $data eq 'ARRAY')
          ? [ map { to_Entity($_) } @{$data} ]
          : to_Entity($data);
      }
    }

    if (ref $data eq 'ARRAY') {
      die $data->{error} if any { defined $_->{error} } @{$data};
    }
    elsif (ref $data eq 'HASH') {
      die $data->{error} if defined $data->{error};
    }

    return $data;
  }
  catch {
    croak $log->fatalf('Could not complete request: %s', $_);
  };
}

1;
