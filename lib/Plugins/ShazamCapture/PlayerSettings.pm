package Plugins::ShazamCapture::PlayerSettings;

use strict;
use base qw(Slim::Web::Settings);

sub name {
	return Slim::Web::HTTP::CSRF->protectName(
		'PLUGIN_SHAZAMCAPTURE_PLAYER_SETTINGS'
	);
}

sub needsClient {
	return 1;
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI(
		'plugins/ShazamCapture/settings/player.html'
	);
}

1;
