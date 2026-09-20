use strict;
use warnings;
use Test::More;

BEGIN {
	package TestLog;
	sub info {}

	package TestPrefs;
	sub get { return }

	package Slim::Utils::Log;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"} = sub { return bless {}, 'TestLog' };
	}
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package Slim::Utils::Prefs;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::preferences"} = sub { return bless {}, 'TestPrefs' };
	}
	$INC{'Slim/Utils/Prefs.pm'} = __FILE__;

	package Slim::Utils::Cache;
	sub new { return bless {}, shift }
	$INC{'Slim/Utils/Cache.pm'} = __FILE__;

	package Slim::Utils::Timers;
	$INC{'Slim/Utils/Timers.pm'} = __FILE__;

	package Slim::Control::Request;
	$INC{'Slim/Control/Request.pm'} = __FILE__;

	package Slim::Music::Info;
	$INC{'Slim/Music/Info.pm'} = __FILE__;

	package Slim::Player::Client;
	$INC{'Slim/Player/Client.pm'} = __FILE__;

	package Plugins::ShazamCapture::Artwork;
	$INC{'Plugins/ShazamCapture/Artwork.pm'} = __FILE__;
}

use lib 'lib';
use Plugins::ShazamCapture::Auto;

my $track = {
	shazam_key => '12345',
	title => 'Song', artist => 'Artist', album => 'Album',
	artwork_url => 'https://example.test/cover.jpg',
};
my $current = {
	track => { title => 'Song', artist => 'Artist', album => 'Album' },
	identity => Plugins::ShazamCapture::Auto::_overlay_identity($track),
	render_station => 'Test FM',
	label_artwork => 1,
};

ok(
	Plugins::ShazamCapture::Auto::_overlay_unchanged(
		$current, $track, 'Test FM', 1
	),
	'an identical successive Shazam result keeps the active overlay',
);
ok(
	!Plugins::ShazamCapture::Auto::_overlay_unchanged(
		$current, { %$track, title => 'Different Song' }, 'Test FM', 1
	),
	'changed published metadata republishes the overlay',
);
ok(
	Plugins::ShazamCapture::Auto::_overlay_unchanged(
		$current,
		{ %$track, artwork_url => 'https://example.test/cover.jpg?token=new' },
		'Test FM', 1
	),
	'a changed artwork query token does not republish an unchanged overlay',
);
ok(
	!Plugins::ShazamCapture::Auto::_overlay_unchanged(
		$current, $track, 'Other FM', 1
	),
	'a station-label change republishes the overlay',
);
ok(
	!Plugins::ShazamCapture::Auto::_overlay_unchanged(
		$current, $track, 'Test FM', 0
	),
	'an artwork-label setting change republishes the overlay',
);

my $metadata_identity = Plugins::ShazamCapture::Auto::_overlay_identity({
	title => '  SONG ', artist => 'The  Artist', album => 'Album',
});
is(
	$metadata_identity,
	Plugins::ShazamCapture::Auto::_overlay_identity({
		title => 'song', artist => 'the artist', album => ' album ',
	}),
	'metadata fallback identity ignores case and whitespace differences',
);

done_testing();
