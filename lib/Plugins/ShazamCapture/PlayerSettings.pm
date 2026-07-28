package Plugins::ShazamCapture::PlayerSettings;

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.shazamcapture');
$prefs->init({
	historyThisPlayerOnly => 0,
	historyFilterField    => 'none',
	historyFilterValue    => '',
	historySortOrder      => 'newest',
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
	return Slim::Web::HTTP::CSRF->protectURI(
		'plugins/ShazamCapture/settings/player.html'
	);
}

sub prefs {
	my ($class, $client) = @_;
	return (
		$prefs->client($client),
		'historyThisPlayerOnly',
		'historyFilterField',
		'historyFilterValue',
		'historySortOrder',
	);
}

sub handler {
	my ($class, $client, $params, @args) = @_;
	if ($params->{saveSettings}) {
		$params->{pref_historyThisPlayerOnly} = 0
			unless defined $params->{pref_historyThisPlayerOnly};

		my %filter = map { $_ => 1 }
			qw(none station source artist title album capture);
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
	}
	return $class->SUPER::handler($client, $params, @args);
}

1;
