use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use lib 'lib';
use Plugins::ShazamCapture::Runtime;

local $ENV{SHAZAMCAPTURE_PYTHON};
local $ENV{SHAZAMCAPTURE_FFMPEG};

my $sandbox = tempdir('runtime-paths-XXXXXX',
	DIR => File::Spec->rel2abs('var/tmp'), CLEANUP => 1);
my $cache = File::Spec->catdir($sandbox, 'cache');
my $plugin = File::Spec->catdir(
	$cache, 'InstalledPlugins', 'Plugins', 'ShazamCapture');
my $external = File::Spec->catdir($cache, 'ShazamCapture-venv');
my $local = File::Spec->catdir($plugin, 'python', 'venv');
my $external_python = File::Spec->catfile($external, 'bin', 'python');
my $local_python = File::Spec->catfile($local, 'bin', 'python');
my $external_ffmpeg = File::Spec->catfile($external, 'lib', 'python3.11',
	'site-packages', 'imageio_ffmpeg', 'binaries', 'ffmpeg-test');
my $local_ffmpeg = File::Spec->catfile($local, 'lib', 'python3.12',
	'site-packages', 'imageio_ffmpeg', 'binaries', 'ffmpeg-test');

make_path($plugin);
Plugins::ShazamCapture::Runtime::init($plugin);
_executable($local_python);
_executable($local_ffmpeg);
is((Plugins::ShazamCapture::Runtime::python())[2], 'plugin',
	'plugin-local Python remains the fallback');
is((Plugins::ShazamCapture::Runtime::ffmpeg())[0], $local_ffmpeg,
	'plugin-local FFmpeg remains the fallback');

_executable($external_python);
_executable($external_ffmpeg);
is_deeply([Plugins::ShazamCapture::Runtime::python()],
	[$external_python, undef, 'cache'],
	'installed plugin prefers the external Docker Python');
is_deeply([Plugins::ShazamCapture::Runtime::ffmpeg()],
	[$external_ffmpeg, undef, 'cache'],
	'installed plugin prefers the matching external FFmpeg');

local $ENV{SHAZAMCAPTURE_PYTHON} = '/nonexistent/shazamcapture-python';
ok(!(Plugins::ShazamCapture::Runtime::python())[0],
	'invalid explicit Python override still fails closed');

done_testing();

sub _executable {
	my ($path) = @_;
	my ($volume, $directory) = File::Spec->splitpath($path);
	make_path(File::Spec->catpath($volume, $directory));
	open my $fh, '>', $path or die "Cannot create $path: $!";
	print {$fh} "#!/bin/sh\nexit 0\n";
	close $fh;
	chmod 0755, $path or die "Cannot make $path executable: $!";
}
