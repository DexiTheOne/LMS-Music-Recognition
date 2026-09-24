use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

BEGIN {
	package Slim::Web::Settings;
	sub handler {}
	$INC{'Slim/Web/Settings.pm'} = __FILE__;

	package Slim::Web::HTTP::CSRF;
	sub protectURI { return $_[1] }
	$INC{'Slim/Web/HTTP/CSRF.pm'} = __FILE__;

	package TestPrefs;
	sub init {}

	package Slim::Utils::Prefs;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::preferences"} = sub { return bless {}, 'TestPrefs' };
	}
	$INC{'Slim/Utils/Prefs.pm'} = __FILE__;

	package Slim::Utils::Strings;
	sub import {}
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package Plugins::ShazamCapture::History;
	$INC{'Plugins/ShazamCapture/History.pm'} = __FILE__;

	package Plugins::ShazamCapture::Plugin;
	our ($version, $base);
	sub _pluginDataFor {
		return $_[1] eq 'version' ? $version : $base;
	}
	$INC{'Plugins/ShazamCapture/Plugin.pm'} = __FILE__;
}

use lib 'lib';
use Plugins::ShazamCapture::Settings;

my $sandbox = tempdir('settings-template-XXXXXX',
	DIR => File::Spec->rel2abs('var/tmp'), CLEANUP => 1);
$Plugins::ShazamCapture::Plugin::base = $sandbox;
$Plugins::ShazamCapture::Plugin::version = '0.3.7';

is(Plugins::ShazamCapture::Settings::page(),
	'plugins/ShazamCapture/settings/basic.html',
	'local development uses the unversioned template');

my $directory = File::Spec->catdir($sandbox, 'HTML', 'EN',
	'plugins', 'ShazamCapture', 'settings');
make_path($directory);
my $alias = File::Spec->catfile($directory, 'basic-v0.3.7.html');
open my $fh, '>', $alias or die "Cannot create $alias: $!";
close $fh;

is(Plugins::ShazamCapture::Settings::page(),
	'plugins/ShazamCapture/settings/basic-v0.3.7.html',
	'installed release uses a new template identity');

$Plugins::ShazamCapture::Plugin::version = '0.3.8';
is(Plugins::ShazamCapture::Settings::page(),
	'plugins/ShazamCapture/settings/basic.html',
	'a missing versioned template falls back safely');

done_testing();
