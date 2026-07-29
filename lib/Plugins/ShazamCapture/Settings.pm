package Plugins::ShazamCapture::Settings;

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::ShazamCapture::History;

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
		'skipConfirmationsAfterTwoNoMatches',
		'retrySampleSeconds', 'retryDelaySeconds',
		'autoRecognition', 'autoMetadataOverlay',
		'autoClearOverlayOnNoMatch', 'autoIgnoredStations',
		'autoCooldownSeconds'
	);
}

sub handler {
	my ($class, $client, $params, @args) = @_;
	my $database_action = $params->{databaseAction} || '';
	if ($database_action) {
		eval {
			if ($database_action eq 'select') {
				my $filename = $params->{databaseSelection} || '';
				my $create = $filename eq '__new__';
				$filename = $params->{newDatabaseName} || '' if $create;
				$filename .= '.sqlite3' if length($filename) && $filename !~ /\.sqlite3\z/i;
				$filename =~ s/\.sqlite3\z/.sqlite3/i;
				Plugins::ShazamCapture::History::select_database($filename, $create);
				$prefs->set('historyDatabase', $filename);
				$params->{warning} = string('PLUGIN_SHAZAMCAPTURE_DATABASE_SELECTED', $filename);
			}
			elsif ($database_action eq 'backup') {
				my $backup = Plugins::ShazamCapture::History::backup();
				$backup =~ s{^.*[/\\]}{};
				$params->{warning} = string('PLUGIN_SHAZAMCAPTURE_DATABASE_BACKED_UP', $backup);
			}
			elsif ($database_action eq 'clear') {
				die string('PLUGIN_SHAZAMCAPTURE_DATABASE_CONFIRM_REQUIRED')
					unless $params->{clearDatabaseConfirmed};
				my $backup = Plugins::ShazamCapture::History::backup_and_clear();
				$backup =~ s{^.*[/\\]}{};
				$params->{warning} = string('PLUGIN_SHAZAMCAPTURE_DATABASE_CLEARED', $backup);
			}
			else {
				die 'Unknown database action';
			}
		};
		if ($@) {
			my $error = $@;
			$error =~ s/\s+$//;
			$error =~ s/\s+at .+? line \d+\.?\z//s;
			$params->{warning} = string(
				'PLUGIN_SHAZAMCAPTURE_DATABASE_ACTION_FAILED', _html($error)
			);
		}
	}
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
	if ($params->{saveSettings} && !defined $params->{pref_skipConfirmationsAfterTwoNoMatches}) {
		$params->{pref_skipConfirmationsAfterTwoNoMatches} = 0;
	}
	for my $name (qw(autoRecognition autoMetadataOverlay autoClearOverlayOnNoMatch)) {
		$params->{"pref_$name"} = 0
			if $params->{saveSettings} && !defined $params->{"pref_$name"};
	}
	$params->{historyDatabases} = Plugins::ShazamCapture::History::databases();
	$params->{activeHistoryDatabase} = Plugins::ShazamCapture::History::active_database();
	$params->{historyDatabaseCount} = Plugins::ShazamCapture::History::count();
	my $result = $class->SUPER::handler($client, $params, @args);
	Plugins::ShazamCapture::Auto::settings_changed() if $params->{saveSettings};
	return $result;
}

sub _html {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/&/&amp;/g;
	$value =~ s/</&lt;/g;
	$value =~ s/>/&gt;/g;
	$value =~ s/"/&quot;/g;
	return $value;
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
