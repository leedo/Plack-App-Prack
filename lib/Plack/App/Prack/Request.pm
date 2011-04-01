package Plack::App::Prack::Request;

use strict;
use warnings;

use JSON;
use Plack::App::Prack::Response;

my @ENV_KEYS = qw/REQUEST_METHOD PATH_INFO QUERY_STRING SCRIPT_NAME
                  REMOTE_ADDR SERVER_ADDR SERVER_NAME SERVER_PORT/;

sub new {
  my ($class, $file, $env) = @_;

  die "env is required" unless $env;
  die "file is required" unless $file;

  my $self = bless {
    env => $env,
    file => $file,
  }, $class;

  $self->connect;
  $self->write;

  return $self;
}

sub connect {
  my $self = shift;

  $self->{sock} = IO::Socket::UNIX->new(Peer => $self->{file});

  if (!$self->{sock}) {
    die "could not connect to nack server at $self->{file}\n";
  }
}

sub response {
  my $self = shift;

  return Plack::App::Prack::Response->new($self->{sock});
}

sub encode {
  my ($self, $data) = @_;
  my $json = encode_json $data;
  return length($json).":".$json.",";
}

sub write {
  my $self = shift;

  my $env = $self->_filter_env($self->{env});
  my $ns = $self->encode($env);

  $self->{sock}->write($ns);
  $self->{sock}->shutdown(1);
}

sub _filter_env {
  my ($self, $env) = @_;

  +{
    map {$_ => $env->{$_}} @ENV_KEYS, grep {/^HTTP_/} keys %$env
  }
}

1;
