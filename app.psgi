use lib 'lib';
use Plack::App::Prack;

my $app = Plack::App::Prack->new(config => "hello.ru");
