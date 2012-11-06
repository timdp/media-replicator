#!/usr/bin/perl

################################################################################
#                                                                              #
# REPLICATOR v20121106                                                         #
# By Tim De Pauw <http://pwnt.be/>                                             #
#                                                                              #
################################################################################
#                                                                              #
# Replicates a directory structure, converting all audio files encountered to  #
# a format of your choice. Supported formats are MP3, Ogg, FLAC and WAV. Also, #
# M3U playlists are converted on the fly.                                      #
#                                                                              #
# Usage: perl replicator.pl IN_DIR OUT_DIR OUT_FORMAT                          #
#                                                                              #
# E.g.:  perl replicator.pl "C:/My Music" "C:/Converted Music" ogg             #
#        perl replicator.pl /home/john/songs /mnt/ipod mp3                     #
#                                                                              #
# You will need to place the following Free utilities under your PATH:         #
#     MediaInfo <http://mediainfo.sourceforge.net/>                            #
#     LAME <http://lame.sourceforge.net/>                                      #
#     OggDec and OggEnc <http://www.vorbis.com/>                               #
#     FLAC <http://flac.sourceforge.net/>                                      #
#     FAAD and FAAC <http://www.audiocoding.com/>                              #
#                                                                              #
################################################################################
#                                                                              #
# This program is free software: you can redistribute it and/or modify it      #
# under the terms of the GNU General Public License as published by the Free   #
# Software Foundation, either version 3 of the License, or (at your option)    #
# any later version.                                                           #
#                                                                              #
# This program is distributed in the hope that it will be useful, but WITHOUT  #
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or        #
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for    #
# more details.                                                                #
#                                                                              #
# You should have received a copy of the GNU General Public License along with #
# this program.  If not, see <http://www.gnu.org/licenses/>.                   #
#                                                                              #
################################################################################

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(mkpath);
use File::Copy qw(copy);

use constant DECODERS => {
	'mp3'  => 'lame --quiet --decode "%file%" -',
	'ogg'  => 'oggdec -q -o - "%file%"',
	'flac' => 'flac --totally-silent -d -o - "%file%"',
	'm4a'  => 'faad -w "%file%"',
	'wav'  => 'cat "%file%"'
};

use constant ENCODERS => {
	'mp3' => 'lame --quiet --vbr-new -V4 --tt "%title%" --ta "%artist%"'
		. ' --tl "%album%" --tc "%comment%" --tg "%genre%" --ty "%date%"'
		. ' - "%file%"',
	'ogg' => 'oggenc2 -Q -q4 --utf8 -a "%artist%" -t "%title%" -l "%album%"'
		. ' -N "%number%" -G "%genre%" -c "COMMENT=%comment%" -d "%date%"'
		. ' -o "%file%" -',
	'flac' => 'flac --totally-silent -T "ARTIST=%artist%" -T "TITLE=%title%"'
		. ' -T "ALBUM=%album%" -T "TRACKNUMBER=%number%" -T "GENRE=%genre%"'
		. ' -T "COMMENT=%comment%" -T "DATE=%date%" -o "%file%" -',
	'm4a' => 'faac -q 100 -w -s --artist "%artist%" --title "%title%"'
		. ' --genre "%genre%" --album "%album%" --track "%number%"'
		. ' --year "%date%" --comment "%comment%" -o "%file%" - >NUL',
	'wav' => 'cat >"%file%"'
};

use constant MEDIAINFO_FIELDS => {
	'Performer' => 'artist',
	'Track name' => 'title',
	'Album' => 'album',
	'Track name/Position' => 'number',
	'Genre' => 'genre',
	'Recorded date' => 'date',
	'Comment' => 'comment'
};

(@ARGV == 3) or die qq{Usage: $0 IN_DIR OUT_DIR OUT_FORMAT};
my ($in_dir, $out_dir, $out_type) = @ARGV;
s|\\|/|g for ($in_dir, $out_dir);
$out_type = lc $out_type;

die qq{Invalid input directory: "$in_dir"}
	unless (-d $in_dir);
die qq{Invalid output directory: "$out_dir"}
	if (-e $out_dir && !-d $out_dir);
die qq{Invalid output format: "$out_type"}
	unless (exists ENCODERS->{$out_type});

mkpath($out_dir);
replicate($in_dir);

sub replicate {
	my $path = shift;
	opendir(my $dh, $path) or die qq{Failed to open "$path": $!};
	my @entries = readdir($dh);
	closedir($dh);
	foreach my $entry (sort { uc($a) cmp uc($b) } @entries) {
		next if ($entry eq '.' || $entry eq '..');
		my $file_path = $path . '/' . $entry;
		if (-d $file_path) {
			replicate($file_path);
		} else {
			my $ext;
			$file_path =~ /([^.]+)$/ and $ext = lc($1);
			if ($ext eq 'm3u' || $ext eq 'm3u8') {
				convert_playlist($file_path);
			} elsif (exists DECODERS->{$ext}) {
				transcode($file_path, $ext);
			} else {
				clone_file($file_path);
			}
		}
	}
}

sub convert_playlist {
	my $path = shift;
	my $new_path = convert_path($path);
	die qq{"$new_path" exists} if (-e $new_path);
	mkpath(dirname($new_path));
	print qq{Converting "$path" to "$new_path" ...}, $/;
	open(my $old_fh, '<', $path) or die qq{Failed to open "$path": $!};
	open(my $new_fh, '>', $new_path) or die qq{Failed to open "$new_path": $!};
	while (my $line = <$old_fh>) {
		chomp $line;
		if ($line !~ /^#/) {
			$line =~ s/([^.]+)$/$out_type/;
		}
		print $new_fh $line, $/;
	}
	close($new_fh);
	close($old_fh);
}

sub transcode {
	my ($path, $type) = @_;
	(my $new_path = convert_path($path)) =~ s/([^.]+)$/$out_type/;
	die qq{"$new_path" exists} if (-e $new_path);
	my $file_data = get_tags($path);
	mkpath(dirname($new_path));
	print qq{Transcoding "$path" to "$new_path" ...}, $/;
	my $dec_cmd = DECODERS->{$type};
	$dec_cmd =~ s/%file%/$path/g;
	my $enc_cmd = ENCODERS->{$out_type};
	$enc_cmd =~ s/%file%/$new_path/g;
	$enc_cmd =~ s{%([a-z]+)%}{
		defined($file_data->{$1}) ? $file_data->{$1} : '';
	}eg;
	my $cmd = sprintf('%s | %s', $dec_cmd, $enc_cmd);
	system $cmd;
}

sub clone_file {
	my $path = shift;
	my $new_path = convert_path($path);
	die qq{"$new_path" exists} if (-e $new_path);
	print qq{Copying "$path" to "$new_path" ...}, $/;
	mkpath(dirname($new_path));
	copy($path, $new_path);
}

sub convert_path {
	return $out_dir . substr($_[0], length($in_dir));
}

sub get_tags {
	my $file_path = shift;
	my %data = ();
	open(my $ph, qq{mediainfo "$file_path" |})
		or die qq{Failed to invoke mediainfo: $!};
	while (my $line = <$ph>) {
		chomp $line;
		last if ($line =~ /^\s*$/);
		if ($line =~ /^(.*?)\s*:\s*(.*?)\s*$/) {
			my ($name, $value) = ($1, $2);
			if (exists MEDIAINFO_FIELDS->{$name}) {
				$value =~ s/"/'/g;
				$data{MEDIAINFO_FIELDS->{$name}} = $value;
			}
		}
	}
	close($ph);
	return \%data;
}

################################################################################
