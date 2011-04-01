package Plack::App::Prack;

use Plack::Util::Accessor qw/config/;
use Plack::App::Prack::Worker;

use parent 'Plack::Component';

sub prepare_app {
  my $self = shift;

  die "configuration \"".$self->config."\" doesn't exist" unless -e $self->config;

  $self->{worker} = Plack::App::Prack::Worker->new(config => $self->config);
}

sub call {
  my ($self, $env) = @_;
  return $self->{worker}->proxy($env);
}

1;
