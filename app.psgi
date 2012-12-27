use Plack::App::Prack;

Plack::App::Prack->new(config => "hello.ru")->to_app;
