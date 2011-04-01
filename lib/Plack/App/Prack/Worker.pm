package Plack::App::Prack::Worker;

use strict;
use warnings;

use Time::HiRes;
use File::Temp ':POSIX';
use IO::Socket::UNIX;
use Plack::App::Prack::Request;

my $NACK = '$0="prack-worker"; Nack::Server.run(ARGV[0], :file => ARGV[1])';
my $OPTS = '-Ilib -rnack/server';

sub new {
  my ($class, %args) = @_;
  die "config is required" unless $args{config} and -e $args{config};

  my $self = bless \%args, $class;  
  $self->spawn;
  
  return $self;
}

sub spawn {
  my $self = shift;

  my $tmp = tmpnam;

  if (fork) {

    # wait up to 3 seconds for the file to show up
    my $count = 3000;
    do { $count--; Time::HiRes::usleep(1000) } while ! -e $tmp && $count;

    my $sock = IO::Socket::UNIX->new(Peer => $tmp);

    if (!$sock) {
      die "could not connect to nack server\n";
    }

    # read the pid
    my $p = $sock->getline;

    $self->{sock} = $sock;
    $self->{file} = $tmp;
  }
  else {
    exec "ruby $OPTS -e'$NACK' $self->{config} $tmp";
  }
}

sub proxy {
  my ($self, $env) = @_;

  my $request = Plack::App::Prack::Request->new($self->{file}, $env);
  my $response = $request->response;

  return $response->to_psgi;
}

1;
