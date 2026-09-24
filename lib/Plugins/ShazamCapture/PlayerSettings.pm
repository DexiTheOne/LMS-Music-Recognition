package Plugins::ShazamCapture::PlayerSettings;

use strict;
use base qw(Slim::Web::Settings);
use File::Spec;
use Plugins::ShazamCapture::History;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.shazamcapture');
$prefs->init({
	historyThisPlayerOnly => 0,
	historyFilterField    => 'none',
	historyFilterValue    => '',
	historySortOrder      => 'newest',
	historyUseCurrentDatabase => 1,
	historyViewDatabasePath   => File::Spec->catfile('var', 'backups', ''),
});

sub name {
	return Slim::Web::HTTP::CSRF->protectName(
		'PLUGIN_SHAZAMCAPTURE_PLAYER_SETTINGS'
	);
}

sub needsClient {
	return 1;
}

sub page {
	return Plugins::ShazamCapture::Settings::template_page('player');
}

sub prefs {
	my ($class, $client) = @_;
	return (
		$prefs->client($client),
		'historyThisPlayerOnly',
		'historyFilterField',
		'historyFilterValue',
		'historySortOrder',
		'historyUseCurrentDatabase',
		'historyViewDatabasePath',
	);
}

sub handler {
	my ($class, $client, $params, @args) = @_;
	if ($params->{saveSettings}) {
		$params->{pref_historyThisPlayerOnly} = 0
			unless defined $params->{pref_historyThisPlayerOnly};
		$params->{pref_historyUseCurrentDatabase} = 0
			unless defined $params->{pref_historyUseCurrentDatabase};

		my %filter = map { $_ => 1 }
			qw(none station source artist title album capture api_source api_reason);
		$params->{pref_historyFilterField} = 'none'
			unless $filter{$params->{pref_historyFilterField} || ''};

		my %sort = map { $_ => 1 }
			qw(newest oldest artist_asc artist_desc title_asc title_desc);
		$params->{pref_historySortOrder} = 'newest'
			unless $sort{$params->{pref_historySortOrder} || ''};

		my $value = $params->{pref_historyFilterValue};
		$value = '' unless defined $value;
		$value =~ s/^\s+|\s+$//g;
		$value = substr($value, 0, 200);
		$params->{pref_historyFilterValue} = $value;
		$params->{pref_historyFilterValue} = ''
			if $params->{pref_historyFilterField} eq 'none';

		if (!defined $params->{pref_historyViewDatabasePath}) {
			my $saved = $prefs->client($client)->get('historyViewDatabasePath');
			$params->{pref_historyViewDatabasePath} = defined $saved
				? $saved
				: File::Spec->catfile('var', 'backups', '');
		}
		my $database_path = $params->{pref_historyViewDatabasePath};
		$database_path =~ s/^\s+|\s+$//g;
		$database_path = substr($database_path, 0, 500);
		$database_path = File::Spec->catfile('var', 'backups', '')
			unless length $database_path;
		my $normalized = eval {
			Plugins::ShazamCapture::History::normalize_view_database_path(
				$database_path
			)
		};
		$database_path = $normalized if defined $normalized && length $normalized;
		$params->{pref_historyViewDatabasePath} = $database_path;
	}
	return $class->SUPER::handler($client, $params, @args);
}

sub beforeRender {
	my ($class, $params, $client) = @_;
	my $saved = $prefs->client($client)->get('historyViewDatabasePath');
	$saved = File::Spec->catfile('var', 'backups', '')
		unless defined $saved && length $saved;
	my $picker_path =
		Plugins::ShazamCapture::History::view_database_picker_path($saved);
	return unless defined $picker_path && length $picker_path;
	$params->{prefs}->{historyViewDatabasePath} = $picker_path;
	$params->{prefs}->{pref_historyViewDatabasePath} = $picker_path;
}

1;
