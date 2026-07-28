package Plugins::ShazamCapture::Settings;

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.shazamcapture');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SHAZAMCAPTURE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI(
		'plugins/ShazamCapture/settings/basic.html'
	);
}

sub prefs {
	return (
		$prefs, 'showSpotifyInHistory', 'flushOnSameStreamMetadata',
		'saveDebugWav',
		'manualSampleMode', 'sampleSeconds', 'retryCount',
		'consecutiveConfirmations',
		'retrySampleSeconds', 'retryDelaySeconds',
		'autoRecognition', 'autoMetadataOverlay', 'autoIgnoredStations',
		'autoCooldownSeconds'
	);
}

sub handler {
	my ($class, $client, $params, @args) = @_;
	if ($params->{saveSettings}) {
		$params->{pref_manualSampleMode} =
			($params->{pref_manualSampleMode} || '') eq 'fresh'
				? 'fresh' : 'buffered';
		_clamp($params, 'pref_sampleSeconds', 5, 30, 10);
		_clamp($params, 'pref_retryCount', 0, 10, 1);
		_clamp($params, 'pref_consecutiveConfirmations', 1, 11, 1);
		_clamp($params, 'pref_retrySampleSeconds', 5, 30, 10);
		_clamp($params, 'pref_retryDelaySeconds', 1, 30, 5);
		_clamp($params, 'pref_autoCooldownSeconds', 30, 900, 120);
	}
	if ($params->{saveSettings} && !defined $params->{pref_showSpotifyInHistory}) {
		$params->{pref_showSpotifyInHistory} = 0;
	}
	if ($params->{saveSettings} && !defined $params->{pref_flushOnSameStreamMetadata}) {
		$params->{pref_flushOnSameStreamMetadata} = 0;
	}
	if ($params->{saveSettings} && !defined $params->{pref_saveDebugWav}) {
		$params->{pref_saveDebugWav} = 0;
	}
	for my $name (qw(autoRecognition autoMetadataOverlay)) {
		$params->{"pref_$name"} = 0
			if $params->{saveSettings} && !defined $params->{"pref_$name"};
	}
	my $result = $class->SUPER::handler($client, $params, @args);
	Plugins::ShazamCapture::Auto::settings_changed() if $params->{saveSettings};
	return $result;
}

sub _clamp {
	my ($params, $key, $min, $max, $default) = @_;
	my $value = $params->{$key};
	$value = $default unless defined $value && $value =~ /^\d+$/;
	$value = $min if $value < $min;
	$value = $max if $value > $max;
	$params->{$key} = int($value);
}

1;
