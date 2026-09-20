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
	sub new { return bless { values => {} }, shift }
	sub get { return $_[0]->{values}->{$_[1]} }
	sub set { $_[0]->{values}->{$_[1]} = $_[2] }
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

{
	package TestSong;
	sub new {
		my $class = shift;
		return bless { @_ }, $class;
	}
	sub pluginData { return $_[0]->{$_[1]} }
	sub icon { return $_[0]->{icon} }
}

is(
	Plugins::ShazamCapture::Auto::_native_artwork(
		TestSong->new(icon => 'https://station.test/logo.png'), undef,
		'hlsplay://station.test/live'
	),
	'https://station.test/logo.png',
	'protocol-handler station artwork is retained when no remote-image cache entry exists',
);
is(
	Plugins::ShazamCapture::Auto::_native_artwork(
		TestSong->new(
			hls_coverurl => 'https://station.test/original-logo.png',
			icon => '/imageproxy/http%3A%2F%2Fserver%2Fplugins%2FShazamCapture%2Fartwork%2Fplayer.jpg/image.jpg',
		),
		{ cover => '/imageproxy/http%3A%2F%2Fserver%2Fplugins%2FShazamCapture%2Fartwork%2Fplayer.jpg/image.jpg' },
		'hlsplay://station.test/live'
	),
	'https://station.test/original-logo.png',
	'PlayHLS station artwork takes precedence over contaminated overlay metadata',
);
is(
	Plugins::ShazamCapture::Auto::_native_artwork(
		TestSong->new(icon => 'html/images/radio.png'),
		{ cover => '/imageproxy/http%3A%2F%2Fserver%2Fplugins%2FShazamCapture%2Fartwork%2Fplayer.jpg/image.jpg' },
		'hlsplay://station.test/live'
	),
	undef,
	'plugin artwork and generic LMS fallback images are not saved as native station artwork',
);

done_testing();
