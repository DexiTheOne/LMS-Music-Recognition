use strict;
use warnings;
use Test::More;

BEGIN {
	package Plugins::ShazamCapture::Plugin;

	our $initialized = 1;
	our $start_result = { ok => 1, started => 1, generation => 7 };
	our @start_args;

	sub initialized {
		return $initialized;
	}

	sub start_recognition {
		shift if $_[0] eq __PACKAGE__;
		@start_args = @_;
		return { %$start_result };
	}

	$INC{'Plugins/ShazamCapture/Plugin.pm'} = __FILE__;

	package Slim::Player::Client;

	our %clients;

	sub getClient {
		my ($id) = @_;
		return $clients{lc($id || '')};
	}

	$INC{'Slim/Player/Client.pm'} = __FILE__;

	package TestClient;

	sub new {
		my ($class, $id) = @_;
		return bless { id => $id }, $class;
	}

	sub id {
		return $_[0]->{id};
	}
}

use lib 'lib';
use Plugins::ShazamCapture::API;

is(Plugins::ShazamCapture::API->api_version(), 1, 'reports API version 1');
ok(Plugins::ShazamCapture::API->available(), 'reports initialized plugin');

is(
	Plugins::ShazamCapture::API->recognize()->{error},
	'player_id is required',
	'requires player ID',
);
is(
	Plugins::ShazamCapture::API->recognize(
		player_id => '00:11:22:33:44:55',
	)->{error},
	'source is required',
	'requires caller source',
);
is(
	Plugins::ShazamCapture::API->recognize(
		player_id => '00:11:22:33:44:55',
		source    => 'Test',
	)->{error},
	'callback must be a code reference',
	'requires completion callback',
);

my $id = '00:11:22:33:44:55';
$Slim::Player::Client::clients{$id} = TestClient->new($id);
my $context = { playlist_id => 42 };
my @callback;
my $accepted = Plugins::ShazamCapture::API->recognize(
	player_id => uc($id),
	source    => " Plugins::LikedSongs\n",
	reason    => " like\n",
	context   => $context,
	callback  => sub { @callback = @_ },
);

ok($accepted->{ok}, 'accepts valid request');
ok($accepted->{accepted}, 'marks request accepted');
like(
	$accepted->{request_id},
	qr/\Ashazamcapture-001122334455-\d+-\d{6}\z/,
	'generates correlation ID',
);
is($accepted->{player_id}, $id, 'returns normalized player ID');
is($Plugins::ShazamCapture::Plugin::start_args[2], 'manual', 'uses manual path');
is_deeply(
	$Plugins::ShazamCapture::Plugin::start_args[4],
	{ sample_mode => undef },
	'normal API trigger leaves sample mode at the global setting',
);
is_deeply(
	$Plugins::ShazamCapture::Plugin::start_args[3],
	{
		api_source => 'Plugins::LikedSongs',
		api_reason => 'like',
	},
	'forwards sanitized API provenance',
);

my $terminal = {
	ok => 1,
	matched => 1,
	stale => 0,
	track => { title => 'Example' },
};
$Plugins::ShazamCapture::Plugin::start_args[1]->($terminal, 7);
is($callback[0], $terminal, 'forwards terminal result');
is($callback[1], $context, 'returns opaque context unchanged');
is($callback[2]->{request_id}, $accepted->{request_id}, 'returns request metadata');
is($callback[2]->{generation}, 7, 'returns completed generation');

my $fresh = Plugins::ShazamCapture::API->recognize_fresh(
	player_id => $id,
	source    => 'Plugins::LikedSongs',
	callback  => sub {},
);
ok($fresh->{accepted}, 'accepts fresh-only API request');
is($Plugins::ShazamCapture::Plugin::start_args[2], 'manual', 'fresh API uses manual path');
is_deeply(
	$Plugins::ShazamCapture::Plugin::start_args[4],
	{ sample_mode => 'fresh' },
	'fresh API forces fresh sampling',
);

$Plugins::ShazamCapture::Plugin::start_result = {
	ok => 0,
	stage => 'automatic',
	error => 'Automatic recognition owns this radio stream',
};
my $blocked = Plugins::ShazamCapture::API->recognize(
	player_id => $id,
	source => 'Plugins::LikedSongs',
	callback => sub {},
);
ok(!$blocked->{accepted}, 'marks manual-path rejection unaccepted');
is($blocked->{stage}, 'automatic', 'preserves rejection stage');

$Plugins::ShazamCapture::Plugin::initialized = 0;
ok(!Plugins::ShazamCapture::API->available(), 'reports uninitialized plugin');

done_testing();
