package App::otftodit;
use 5.008001;

#!/home/obuk/.plenv/shims/perl
# Copyright 1989-2010 Free Software Foundation, Inc.
#           2022-2024 G. Branden Robinson
#
# Written by James Clark (jjc@jclark.com)
# Enhanced by: Werner Lemberg <wl@gnu.org>
#              G. Branden Robinson <g.branden.robinson@gmail.com>
#
# This file is part of groff, the GNU roff typesetting system.
#
# groff is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# groff is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use warnings;
use strict;

use feature 'say';

our $VERSION = "0.01";

use Carp qw(confess);
use Encode;
use List::Util qw(max min);

use Font::TTF::Font;
use App::otftodit::BBox;
use App::otftodit::Plot;
use App::otftodit::Unicode qw(:all);

use Unicode::UCD qw/charblocks/;

sub run {
    my $class = shift;
    $class->new(@_)->init()->process();
}

sub new {
    my $class = shift;
    bless { @_ }, $class;
}

our $program_name;
our $groff_sys_fontdir;
our $want_help;
our $space_width;

our ($opt_a, $opt_c, $opt_d, $opt_e, $opt_f, $opt_i, $opt_k,
     $opt_m, $opt_n, $opt_o, $opt_q, $opt_s, $opt_v, $opt_w, $opt_x);

our @ot_feature;
our %ot_feature;
our $opt_vertical;
our $skip_nonames;
our $opt_Ncid;
our $opt_mafm;
our $debug;

# for diagnostics
our $filename;
our $lineno = 0;

our $output_version;

#our $afm;
our $otffile;
our $afmfile;
our $map;
our $fontfile;
our $outfile;
our $desc;
our $sys_map;
our $sys_desc;

sub init {
    my ($self) = @_;

use File::Spec;
(undef,undef,our $program_name)=File::Spec->splitpath($0);

#my $groff_sys_fontdir = $ENV{GROFF_SYS_FONT} || "/usr/local/share/groff/current/font";
our $groff_sys_fontdir = $ENV{GROFF_SYS_FONT} || "$ENV{HOME}/share/groff/current/font";
our $want_help;
our $space_width = 0;

use Getopt::Long qw(:config gnu_getopt);
GetOptions( "a=s", "c", "d=s", "e=s", "f=s", "i=s", "k", "m", "n",
  "o=s", "q", "s", "v", "w=i", "x", "version" => \$opt_v,
  "help" => \$want_help,
  "F=s" => \@ot_feature,
  "N|Ncid" => \ our $opt_Ncid,
  "S|skip-nonames" => \ our $skip_nonames,
  "V|vertical" => \ our $opt_vertical,
  "mafm|miniafm" => \ $opt_mafm,
  "bb|bbox=s" => \ our @opt_bbox,
  "verify" => \ our $opt_verify,
  "D" => \ our $debug,
);

our %ot_feature;
for (@ot_feature) {
    my ($k, $v) = split /=/;
    if (defined $v) {
	my @v = split /,/, $v;
	@v = (undef, undef, $v[0]) if @v == 1;
	$v[0] ||= '*';
	$v[1] ||= '*';
	$v[2] ||= $k;
	$ot_feature{$k} = join ',', @v;
    } else {
	$ot_feature{$k} = join ',', '*', '*', $k;
    }
}

# for diagnostics
#our $filename;
#our $lineno = 0;

# We keep these two scalars separate so we can report out the option.
$space_width = $opt_w if defined $opt_w;

# Preserve the Git revision and partial hash from development builds in
# `--version` output, but scrub it from comments written to files.
my $groff_version = "1.24.0";
my $short_version = $groff_version;
$short_version =~ s/(\d+\.\d+.\d+).*/$1/;

#my $version_stub = "GNU afmtodit (groff) version";
my $version_stub = "GNU otfodit (groff) version";
my $afmtodit_version = "$version_stub $groff_version";
our $output_version = "$version_stub $short_version";

if ($opt_v) {
    print "$afmtodit_version\n";
    exit 0;
}

usage(0) if ($want_help);

if ($#ARGV != 2 && $#ARGV != 3) {
    print STDERR "$program_name: usage error: insufficient arguments\n";
    usage(1);
}

    for my $i (0 .. 1) {
	if (open my ($f), $ARGV[$i]) {
	    local $_ = <$f>;
	    close $f;
	    if (length >= 4 && /^OTTO/) {
		$otffile = $ARGV[$i];
	    }
	    if (length >= 16 && /^StartFontMetrics/) {
		$afmfile = $ARGV[$i];
	    }
	}
    }
    usage(1) unless $otffile;

    shift @ARGV if $otffile;
    shift @ARGV if $afmfile;

    $self;
} # end of init

sub croak {
    my $msg = shift;
    my $pos = "";
    $pos .= "$filename:" if $filename;
    $pos .= "$lineno:" if $lineno;
    print STDERR "$program_name:$pos error: $msg\n";
    exit(1);
}

sub whine {
    my $msg = shift;
    my $pos = "";
    $pos .= "$filename:" if $filename;
    $pos .= "$lineno:" if $lineno;
    print STDERR "$program_name:$pos warning: $msg\n";
}

sub usage {
    my $stream = *STDOUT;
    my $had_error = shift;
    $stream = *STDERR if $had_error;
    print $stream "usage: $program_name [-ckmnsxNSV] [-a slant]" .
	" [-d device-description-file] [-e encoding-file]" .
	" [-f internal-name] [-i italic-correction-factor]" .
	" [-o output-file] [-w space-width]" .
	" [-F opentype-feature]" .
	" [-]" .
	" otf-file [afm-file] map-file" .
	" font-description-file\n" .
	"usage: $program_name {-v | --version}\n" .
	"usage: $program_name --help\n";
    print $stream "(experimental options)\n",
	"-F liga|kern|palt|vpal|vrt2|vkna|...\n" .
	"-N allows cid using the \\N escape\n" .
	"-S skips glyphs no name, no unicode\n" .
	"-V vertical writing (rotates metrics)\n";
    unless ($had_error) {
	print $stream "\n" .
"Generate a font description file for use with groff(1)'s 'ps' and\n" .
"'pdf' output devices from an OpenType/CFF file, otf-file, and\n" .
"an Adobe Font Metric file, afm-file.\n" .
"See the afmtodit(1) manual page.\n";
    }
    my $status = 0;
    $status = 2 if ($had_error);
    exit($status);
}

our $psname;
our ($notice, $version, $fullname, $familyname, @comments);
our ($weight, $fontbbox);
our $italic_angle = 0;
our (@kern1, @kern2, @kernx);
our (%italic_correction, %left_italic_correction);
our %subscript_correction;
# my %ligs
our %ligatures;
our (@encoding, %in_encoding);
our (%width, %height, %depth);
our (%left_side_bearing, %right_side_bearing);

our $otf;
our $characterset;
our $iscidfont;
our ($gsub, @gsub_index);
our ($gpos, @gpos_index);
our ($gid2cid, $cid2gid);
our %gid_to_utf8;
our %gid_hint;
our $gid_space;
our $cid_space;
our %n2c;			# xxxxx
our $ascender;
our $descender;
our $default_width  = 1000;
our $default_height = 1000;

sub process {
    my ($self) = @_;

our $map = $ARGV[0];
our $fontfile = $ARGV[1];
our $outfile = $opt_o || $fontfile;
our $desc = $opt_d || "DESC";
our $sys_map = $groff_sys_fontdir . "/devps/generate/" . $map;
our $sys_desc = $groff_sys_fontdir . "/devps/" . $desc;

    read_otf_file();
    read_afm_file();
    read_otf_file_p2();
    read_DESC_file();
    read_encoding_file() if $opt_e;
    read_map_file();
    do_names() if !$opt_x;
    do_ligatures();
    print_groff_font();
    print_mini_afm() if $opt_mafm;

} # end of process


sub verify {
    my $vopts = ref $_[0]
	? shift
	: { };
    my ($k, $got) = @_;
    my $expected = eval "\$$k";
    my $cond;
    if ($got =~ /^[+-]?[\d.]+$/) { # number expected
	if (defined $expected && $expected =~ /^[+-]?\d+$/) {
	    my $e = defined $vopts && $vopts->{e}; # allows margin of error
	    if (defined $e && $e =~ /^[+-]?\d+$/) {
		$cond = ($expected - $e) <= $got && $got <= ($expected + $e);
	    } else {
		$cond = $got == $expected;
	    }
	}
    }
    unless (defined $cond) {
	if (!defined $got && !defined $expected) {
	    $cond = 1;
	} elsif (!defined $got || !defined $expected) {
	    $cond = 0;
	} else {
	    $cond = $got eq $expected;
	}
    }
    unless ($cond) {
	my $got = $got // 'undef';
	my $expected = $expected // 'undef';
	say STDERR "verify: \$$k expected: $expected => got: $got";
    }
    $cond;
}


sub read_afm_file {
    our $opt_verify;
    my $vopts = { e => 5 };

    unless ($afmfile) {
	if ($opt_verify) {
	    warn "$program_name: cannot verify; also specify afm.\n";
	    $opt_verify = 0;
	}
	return undef;
    }

    # read the afm file
if (open(AFM, $afmfile)) {
    $filename = $afmfile;
}
else {
    croak("cannot open '$ARGV[0]': $!");
}

while (<AFM>) {
    $lineno++;
    chomp;
    s/\x0D$//;
    my @field = split(' ');
    next if $#field < 0;
    if ($field[0] eq "FontName") {
	my $psname = $field[1];
	if($opt_f) {
	    $psname = $opt_f;
	}
	verify $vopts, psname => $psname or
	    croak "$afmfile does not match $field[0] of $otffile"
	    if $opt_verify;
    }
    elsif($field[0] eq "Notice") {
	my $notice = $_;
	verify $vopts, notice => "@field[1..$#field]" if $opt_verify;
    }
    elsif($field[0] eq "Version") {
	my $version = $_;
	verify $vopts, version => $field[1] if $opt_verify;
    }
    elsif($field[0] eq "FullName") {
	my $fullname = $_;
	verify $vopts, fullname => $fullname if $opt_verify;
    }
    elsif($field[0] eq "FamilyName") {
	my $familyname = $_;
	verify $vopts, familyname => $familyname if $opt_verify;
    }
    elsif($field[0] eq "CharacterSet") {
	my $characterset = $field[1];
	verify $vopts, characterset => $characterset if $opt_verify;
    }
    elsif($field[0] eq "Comment") {
	push(@comments, $_);
    }
    elsif($field[0] eq "IsCIDFont") {
	my $iscidfont = lc($field[1]) eq 'true';
	verify $vopts, iscidfont => $iscidfont if $opt_verify;
    }
    elsif($field[0] eq "ItalicAngle") {
	$italic_angle = -$field[1];
    }
    elsif ($field[0] eq "KPX") {

	# ignores KPX line, prefers OpenType 'kern' feature.

=begin comment

	if ($#field == 3) {
	    push(@kern1, $field[1]);
	    push(@kern2, $field[2]);
	    push(@kernx, $field[3]);
	}

=end comment

=cut

    }

=begin comment

    elsif ($field[0] eq "italicCorrection") {
	$italic_correction{$field[1]} = $field[2];
    }
    elsif ($field[0] eq "leftItalicCorrection") {
	$left_italic_correction{$field[1]} = $field[2];
    }
    elsif ($field[0] eq "subscriptCorrection") {
	$subscript_correction{$field[1]} = $field[2];
    }

=end comment

=cut

    elsif ($field[0] eq "StartCharMetrics") {
	croak "not a cidfont" unless $iscidfont;
	while (<AFM>) {
	    @field = split(' ');
	    next if $#field < 0;
	    last if ($field[0] eq "EndCharMetrics");
	    if ($field[0] eq "C") {
		my $w_afm;
		#my $wx = 0;
		my $n = "";
#		%ligs = ();
		my $lly = 0;
		my $ury = 0;
		my $llx = 0;
		my $urx = 0;
		my $c_afm = $field[1];
		my $i = 2;
		while ($i <= $#field) {
		    if ($field[$i] eq "WX") {
			$w_afm = $field[$i + 1];
			$i += 2;
		    }
		    elsif ($field[$i] eq "W0X") {
			$w_afm = $field[$i + 1];
			$i += 2;
		    }
		    elsif ($field[$i] eq "N") {
			$n = $field[$i + 1];
			$i += 2;
		    }
		    elsif ($field[$i] eq "B") {
			$llx = $field[$i + 1];
			$lly = $field[$i + 2];
			$urx = $field[$i + 3];
			$ury = $field[$i + 4];
			$i += 5;
		    }
#		    elsif ($field[$i] eq "L") {
#			$ligs{$field[$i + 2]} = $field[$i + 1];
#			$i += 3;
#		    }
		    else {
			while ($i <= $#field && $field[$i] ne ";") {
			    $i++;
			}
			$i++;
		    }
		}

		my $cid = $n;
		my $gid = $cid2gid->[$cid];

		my $u = $gid_to_utf8{$gid};
		my @c = @$u if ref $u;
		my $c = @c ? unpack 'n*', encode 'UTF16-BE', $c[0] : -1;

		if (my $subst = find_gsub($gid, "gsub")) {
		    $gid = $subst;
		    $cid = $gid2cid->[$gid];
		    $n2c{$cid} = $c if $c != -1;
		    $c = -1;
		}

		my $wx  = $otf->{'hmtx'}{'advance'}[$gid];
		my $hx  = $otf->{'vmtx'}{'advance'}[$gid];
		my $lsb = $otf->{'hmtx'}{'lsb'}[$gid];
		my $top = $otf->{'vmtx'}{'top'}[$gid];

		my $w = $wx;
		my $h = $hx;
		my $o = 0;
		if ($gpos) {
		    for ($gpos->{$gid}{XAdvance}) {
			$w += $_ if defined;
		    }
		    for ($gpos->{$gid}{XPlacement}) {
			$o += $_ if defined;
		    }
		    for ($gpos->{$gid}{YAdvance}) {
			$h += $_ if defined;
		    }
		    for ($gpos->{$gid}{YPlacement}) {
			$o += $_ if defined;
		    }
		}

		my ($o_llx, $o_lly) = ($llx, $lly);
		my ($o_urx, $o_ury) = ($urx, $ury);
		if ($opt_a) {
		    my $ta = 0;
		    my $tb = $opt_a / 180 * pi();
		    my $M = [ 1, 0, sin($tb) / cos($tb), 1, 0, 0 ];
		    ($llx, $lly) = mmul([$llx, $lly], $M);
		    ($urx, $ury) = mmul([$urx, $ury], $M);
		}
		if ($opt_vertical) {
		    #my $t = 90 / 180 * pi();
		    #my $M = [ cos($t), sin($t), -sin($t), cos($t), 0, 0 ];
		    my $M = [ 0, 1, -1, 0, 0, 0 ];
		    my ($px, $py) = mmul([$llx, $lly], $M);
		    my ($qx, $qy) = mmul([$urx, $ury], $M);
		    $px += 1000 + $descender; $py += $descender;
		    $qx += 1000 + $descender; $qy += $descender;
		    ($llx, $lly) = (min($px, $qx), min($py, $qy));
		    ($urx, $ury) = (max($px, $qx), max($py, $qy));
		    ($w, $h) = ($h, $w);
		}

		#if (!$opt_e && $c != -1) {
		if (!$opt_e && $c != -1 || $c >= 256) {
		    if ($opt_Ncid) {
			if (defined $encoding[$n] && $encoding[$n] ne $n) {
			    say STDERR "overwriting \$encoding[$n]: $encoding[$n] => $n";
			}
			$encoding[$n] = $n;
		    } else {
			$encoding[$c] = $n;
		    }
		    $in_encoding{$n} = 1;
		}

		$width{$n} = $w;
		$height{$n} = $ury;
		$depth{$n} = -$lly;
		$left_side_bearing{$n} = -$llx;
		$right_side_bearing{$n} = $urx - $w;
#		foreach my $lig (sort keys %ligs) {
#		    $ligatures{$lig} = $n . " " . $ligs{$lig};
#		}
	    }
	}
    }
}
close(AFM);
$filename = "";
$lineno = 0;

=begin comment

    for my $n (sort { $a <=> $b } keys %n2c) {
	my $c = $n2c{$n};
	if (!$opt_e && $c != -1 || $c >= 256) {
	    if ($opt_Ncid) {
		if (defined $encoding[$n] && $encoding[$n] ne $n) {
		    say STDERR "overwriting \$encoding[$n]: $encoding[$n] => $n";
		}
		$encoding[$n] = $n;
	    } else {
		if (defined $encoding[$c] && $encoding[$c] ne $n) {
		    say STDERR "overwriting \$encoding[$c]: $encoding[$c] => $n";
		}
		$encoding[$c] = $n;
	    }
	    $in_encoding{$n} = 1;
	}
    }

    my $option = $ot_feature{kern};# // '*,*,kern';
    if (my $kern = gpos($otf, grep defined, ot_feature($otf, 'GPOS', $option))) {
	my @kern;
	while (my ($k, $v) = each %$kern) {
	    my ($g1, $g2) = split $;, $k;
	    my ($c1, $c2) = map $gid2cid->[$_], $g1, $g2;
	    my $x = !$opt_vertical ? $kern->{$k}{XAdvance} : $kern->{$k}{YAdvance};
	    if (defined $c1 && defined $c2 && defined $x) {
		push @kern, [$c1, $c2, $x];
	    }
	}
	for (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @kern) {
	    push @kern1, $_->[0];
	    push @kern2, $_->[1];
	    push @kernx, $_->[2];
	}
    }

=end comment

=cut

} # end of read_afm_file


sub read_otf_file {
    $otf = Font::TTF::Font->open($otffile) or
	croak "can't open $fontfile\n";

    $otf->{'CFF '}->read;
    my $cff = $otf->{'CFF '};
    if ($cff->TopDICT) {
	if (my $ROS = $cff->TopDICT->{ROS}) {
	    $characterset = join '-', @$ROS;
	    $iscidfont = 1;
	}
	$notice     = $cff->TopDICT->{Notice};
	$familyname = $cff->TopDICT->{FamilyName};
	$fullname   = $cff->TopDICT->{FullName};
	$version    = $cff->TopDICT->{CIDFontVersion};
	$psname     = $cff->TopDICT->{FontName};
	$weight     = $cff->TopDICT->{Weight};
	$fontbbox   = $cff->TopDICT->{FontBBox};
    }

    $notice     //= get_name($otf, 0);
    $weight     //= get_name($otf, 2);
    $familyname //= join ' ', grep defined, get_name($otf, 1), $weight;
    $fullname   //= get_name($otf, 4);
    $version    //= get_name($otf, 5);
    $psname     //= get_name($otf, 6);
    $fontbbox   //= [ map $otf->{'head'}->{$_}, qw/xMin yMin xMax yMax/ ];

    if ($notice) {
	$notice =~ s/\xA9/(C)/g;
    }

    die "$otffile is not OpenType/CFF\n" unless $iscidfont;

    while (my ($k, $v) = each %ot_feature) {
	next if $k =~ /liga|kern/;
	push @gsub_index, grep defined, ot_feature($otf, 'GSUB', $v);
	push @gpos_index, grep defined, ot_feature($otf, 'GPOS', $v);
    }

    $gsub = gsub($otf, @gsub_index);
    $gpos = gpos($otf, @gpos_index);

    $gid2cid = $cff->Charset->{code};
    for my $gid (0 .. $#{$gid2cid}) {
	my $cid = $gid2cid->[$gid];
	$cid2gid->[$cid] = $gid if defined $cid;
    }
    $otf->{cmap}->read;
    my $uv_gid = $otf->{'cmap'}->find_ms->{val};
    $gid_space = $uv_gid->{0x20};
    $cid_space = $gid2cid->[$gid_space];
    while (my ($uv, $gid) = each %{$uv_gid}) {
	if (my $subst = find_gsub($gid)) {
	    $gid = $subst;
	}
	push @{$gid_to_utf8{$gid}}, pack "U", $uv;
    }

    my $umap = $otf->{cmap}->find_uvs->{val};
    for my $uvs (keys %{$umap}) {
	for my $uv (keys %{$umap->{$uvs}}) {
	    my $gid = $umap->{$uvs}{$uv} // $uv_gid->{$uv};
	    if (my $subst = find_gsub($gid)) {
		$gid = $subst;
	    }
	    push @{$gid_to_utf8{$gid}}, pack "U*", $uv, $uvs;
	}
    }

    if (my $subst = find_gsub($gid_space)) {
	$gid_space = $subst;
    }
    $cid_space = $gid2cid->[$gid_space];

    if (ref $gid_to_utf8{$gid_space}) {
	$gid_to_utf8{$gid_space} = do {
	    my %seen;
	    [ grep !$seen{$_}++, chr(0x20), @{$gid_to_utf8{$gid_space}} ];
	};
    }

    $otf->{'OS/2'}->read;
    our $ascender  = $otf->{'OS/2'}->{sTypoAscender}  // $otf->{'head'}->{yMax};
    our $descender = $otf->{'OS/2'}->{sTypoDescender} // $otf->{'head'}->{yMin};

    $otf->{'hmtx'}->read;
    $otf->{'vmtx'}->read;
}

sub read_otf_file_p2 {

    our @opt_bbox;
    my %opt_bbox_cid = map { $_ => 1 } map { split /,/ }
	map { s/\b(\d+)[.][.](\d+)\b/join ',', $1..$2/ge; $_ } @opt_bbox;

    # Comment
    # ItalicAngle
    # KPX
    # italicCorrection
    # leftItalicCorrection
    # subscriptCorrection
    # StartCharMetrics .. EndCharMetrics

    my $cff = $otf->{'CFF '};
    my $pen = App::otftodit::BBox->new(bezier_extrema => 1);
    die "can't run plot" unless $cff->can('plot');

    my %stdbbox;
    my %stdenc;
    for my $sid (@{$cff->StandardEncoding}) {
	my $name = $cff->StandardStrings->[$sid];
	if ($sid == 0) {
	    $stdenc{0} = $name;
	} else {
	    next unless my $unicode = $AGL_to_unicode{$name};
	    next unless my $gid = $otf->{'cmap'}->find_ms->{val}{hex $unicode};
	    $stdenc{$gid} = $name;
	}
    }

    %n2c = ();
    for my $gid (0 .. $#{$gid2cid}) {
	my $cid = $gid2cid->[$gid];

	my $n = $cid;
	my $u = $gid_to_utf8{$gid};
	my @c = @$u if ref $u;
	my $c = @c ? unpack 'n*', encode 'UTF16-BE', $c[0] : -1;

	if (my $subst = find_gsub($gid, "gsub")) {
	    $gid = $subst;
	    $n = $cid = $gid2cid->[$gid];
	    $n2c{$n} = $c if $c != -1;
	    $c = -1;
	}

	my $wx  = $otf->{'hmtx'}{'advance'}[$gid];
	my $hx  = $otf->{'vmtx'}{'advance'}[$gid];
	my $lsb = $otf->{'hmtx'}{'lsb'}[$gid];
	my $top = $otf->{'vmtx'}{'top'}[$gid];

	my $w = $wx;
	my $h = $hx;
	my $o = 0;
	if ($gpos) {
	    for ($gpos->{$gid}{XAdvance}) {
		$w += $_ if defined;
	    }
	    for ($gpos->{$gid}{XPlacement}) {
		$o += $_ if defined;
	    }
	}
	if ($gpos) {
	    for ($gpos->{$gid}{YAdvance}) {
		$h += $_ if defined;
	    }
	    for ($gpos->{$gid}{YPlacement}) {
		$o += $_ if defined;
	    }
	}

	my ($llx, $lly, $urx, $ury);
	our $opt_verify;
	if ($opt_verify || !$afmfile || %opt_bbox_cid) {

	    # $llx = $lsb;
	    # $lly = $descender;
	    # $urx = $wx - $lsb + 1;
	    # #$ury = $ascender;
	    # $ury = $ascender - $top;

	    $pen->init;
	    $cff->plot($gid, $pen);
	    if ($pen->can('bbox')) {
		for (scalar $pen->bbox) {
		    ($llx, $lly, $urx, $ury) = @$_ if ref;
		}
	    }

	    if ($stdenc{$gid}) {
		$stdbbox{$gid} = [ $llx, $lly, $urx, $ury ];
	    }

	    my ($o_llx, $o_lly) = ($llx, $lly);
	    my ($o_urx, $o_ury) = ($urx, $ury);
	    if ($opt_a) {
		my $ta = 0;
		my $tb = $opt_a / 180 * pi();
		my $M = [ 1, 0, sin($tb) / cos($tb), 1, 0, 0 ];
		($llx, $lly) = mmul([$llx, $lly], $M);
		($urx, $ury) = mmul([$urx, $ury], $M);
	    }
	    if ($opt_vertical) {
		#my $t = 90 / 180 * pi();
		#my $M = [ cos($t), sin($t), -sin($t), cos($t), 0, 0 ];
		my $M = [ 0, 1, -1, 0, 0, 0 ];
		my ($px, $py) = mmul([$llx, $lly], $M);
		my ($qx, $qy) = mmul([$urx, $ury], $M);
		$px += 1000 + $descender; $py += $descender;
		$qx += 1000 + $descender; $qy += $descender;
		($llx, $lly) = (min($px, $qx), min($py, $qy));
		($urx, $ury) = (max($px, $qx), max($py, $qy));
		$w = $h if defined $h;
		$h = $w if defined $w;
	    }

	    my $not_ok = 0;
	    if ($opt_verify && $afmfile) {
		my $vopts = { e => 5 };
		$not_ok++ unless verify $vopts, "width{$n}" => $w;
		$not_ok++ unless verify $vopts, "height{$n}" => $ury;
		$not_ok++ unless verify $vopts, "depth{$n}" => -$lly;
		$not_ok++ unless verify $vopts, "left_side_bearing{$n}" => -$llx;
		$not_ok++ unless verify $vopts, "right_side_bearing{$n}" => $urx - $w;
	    }
	    if ($not_ok) {
		say STDERR "# AFM: ", join ' ; ',
		    #"C $c",
		    "W0X $width{$n}", "N $n",
		    join ' ', "B", -$left_side_bearing{$n}, -$depth{$n},
		    $width{$n} + $right_side_bearing{$n}, $height{$n}
		    if $afmfile;
		say STDERR "# OTF: ", join ' ; ',
		    #"C $c",
		    "W0X $w", "N $n",
		    "B $llx $lly $urx $ury";
	    }
	    if ($not_ok || $opt_bbox_cid{$n}) {
		my $pen = App::otftodit::Plot->new;
		$pen->init;
		if ($pen->can('image')) {
		    $pen->image->polyline(
			points => [
			    map [ $pen->mmul($_) ],
			    [ 0  - $o, $descender ],
			    [ $w - $o, $descender ],
			    [ $w - $o, $ascender  ],
			    [ 0  - $o, $ascender  ],
			    [ 0  - $o, $descender ],
			],
			color => Imager::Color->new(
			    map { ($_ >> 16) & 0xff, ($_ >> 8) & 0xff, $_  & 0xff }
			    0x87cefa, # .defcolor lightskyblue rgb #87cefa
			    # 0xb0e2ff, # .defcolor lightskyblue1 rgb #b0e2ff
			    # 0xa4d3ee, # .defcolor lightskyblue2 rgb #a4d3ee
			    # 0x8db6cd, # .defcolor lightskyblue3 rgb #8db6cd
			    # 0x607b8b, # .defcolor lightskyblue4 rgb #607b8b
			), # sky blue
		    );
		    if ($afmfile) {
			# OTF
			my $llx = -$left_side_bearing{$n};
			my $lly = -$depth{$n};
			my $urx = $width{$n} + $right_side_bearing{$n};
			my $ury = $height{$n};
			$pen->image->polyline(
			    points => [
				map [ $pen->mmul($_) ],
				[ $llx, $lly ],
				[ $urx, $lly ],
				[ $urx, $ury ],
				[ $llx, $ury ],
				[ $llx, $lly ],
			    ],
			    color => Imager::Color->new(
				# 255, 255, 0 # yellow
				map { ($_ >> 16) & 0xff, ($_ >> 8) & 0xff, $_  & 0xff }
				0xffa500, # .defcolor orange rgb #ffa500
				#0xffa500, # .defcolor orange1 rgb #ffa500
				#0xee9a00, # .defcolor orange2 rgb #ee9a00
				#0xcd8500, # .defcolor orange3 rgb #cd8500
				#0x8b5a00, # .defcolor orange4 rgb #8b5a00
			    ),
			);
		    }
		    # AFM
		    $pen->image->polyline(
			points => [
			    map [ $pen->mmul($_) ],
			    [ $llx, $lly ],
			    [ $urx, $lly ],
			    [ $urx, $ury ],
			    [ $llx, $ury ],
			    [ $llx, $lly ],
			],
			color => Imager::Color->new(0, 255, 0), # green
		    );
		}
		my $cff = $otf->{'CFF '};
		$cff->plot($gid, $pen);
		if ($pen->can('image')) {
		    -d "tmp" or mkdir 'tmp';
		    say STDERR "# writing ./tmp/$cid.png"; # xxxxx
		    $pen->image->write(file => "./tmp/$cid.png");
		}
		die "can't verify\n" if $not_ok;
	    }
	}			# $opt_verify || !$afmfile

	if (!$opt_verify && !$afmfile) {
	    #if (!$opt_e && $c != -1) {
	    if (!$opt_e && $c != -1 || $c >= 256) {
		if ($opt_Ncid) {
		    if (defined $encoding[$n] && $encoding[$n] ne $n) {
			say STDERR "overwriting \$encoding[$n]: $encoding[$n] => $n";
		    }
		    $encoding[$n] = $n;
		} else {
		    $encoding[$c] = $n;
		}
		$in_encoding{$n} = 1;
	    }
	    $width{$n} = $w // $wx;
	    $height{$n} = $ury;
	    $depth{$n} = -$lly;
	    $left_side_bearing{$n} = -$llx;
	    $right_side_bearing{$n} = $urx - ($w // $wx);

#	    foreach my $lig (sort keys %ligs) {
#		$ligatures{$lig} = $n . " " . $ligs{$lig};
#	    }
	}
    }

    for my $n (sort { $a <=> $b } keys %n2c) {
	my $c = $n2c{$n};
	if (!$opt_e && $c != -1 || $c >= 256) {
	    if ($opt_Ncid) {
		if (defined $encoding[$n] && $encoding[$n] ne $n) {
		    say STDERR "overwriting \$encoding[$n]: $encoding[$n] => $n";
		}
		$encoding[$n] = $n;
	    } else {
		if (defined $encoding[$c] && $encoding[$c] ne $n) {
		    say STDERR "overwriting \$encoding[$c]: $encoding[$c] => $n";
		}
		$encoding[$c] = $n;
	    }
	    $in_encoding{$n} = 1;
	}
    }

    my $option = $ot_feature{kern};# // '*,*,kern';
    if (my $kern = gpos($otf, grep defined, ot_feature($otf, 'GPOS', $option))) {
	my @kern;
	while (my ($k, $v) = each %$kern) {
	    my ($g1, $g2) = split $;, $k;
	    my ($c1, $c2) = map $gid2cid->[$_], $g1, $g2;
	    my $x = !$opt_vertical ? $kern->{$k}{XAdvance} : $kern->{$k}{YAdvance};
	    if (defined $c1 && defined $c2 && defined $x) {
		push @kern, [$c1, $c2, $x];
	    }
	}
	for (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @kern) {
	    push @kern1, $_->[0];
	    push @kern2, $_->[1];
	    push @kernx, $_->[2];
	}
    }

    if (%stdbbox) {
	my $xMin = min(map $_->[0], values %stdbbox);
	my $yMin = min(map $_->[1], values %stdbbox);
	my $xMax = max(map $_->[2], values %stdbbox);
	my $yMax = max(map $_->[3], values %stdbbox);
	$fontbbox = [ $xMin, $yMin, $xMax, $yMax ];
    }

} # end of read_otf_file


sub InCJKIdeographs {
    join '', map { sprintf "%04X\t%04X\n", $_->[0], $_->[1] }
	grep_charblocks(qr/CJK\b.*?\bIdeographs/);
}


sub grep_charblocks {
  grep { $_->[2] =~ /$_[0]/ }
    sort { $a->[0] <=> $b->[0] }
    map { @$_ }
    values %{ charblocks() },
    [
      [
	0x3099, 0x309A,
	"Combining Katakana-Hiragana Voiced Sound Marks"
      ],
    ];
}


sub get_name {
    my ($otf, $number, $platform_id, $encoding_id, $language_id) = @_;
    $platform_id //= 3;
    $encoding_id //= 1;
    $language_id //= 0x409;
    $otf->{name}->read;
    $otf->{name}{strings}[$number][$platform_id][$encoding_id]{$language_id};
}

sub pi {
    3.14159265358979323846;
}

sub mmul {
    my ($x, $y) = @{$_[0]};
    my ($a, $b, $c, $d, $e, $f) = @{$_[1]};
    ($a * $x + $c * $y + $e,
     $b * $x + $d * $y + $f);
}

# read the DESC file

our ($sizescale, $resolution, $unitwidth);

sub read_DESC_file {
$sizescale = 1;

if (open(DESC, $desc)) {
    $filename = $desc;
}
else {
    whine("cannot open '$desc': $!");
    if (open(DESC, $sys_desc)) {
	$filename = $sys_desc;
    }
    else {
	croak("cannot open '$sys_desc': $!");
    }
}

while (<DESC>) {
    $lineno++;
    next if /^#/;
    chop;
    my @field = split(' ');
    next if $#field < 0;
    last if $field[0] eq "charset";
    if ($field[0] eq "res") {
	$resolution = $field[1];
    }
    elsif ($field[0] eq "unitwidth") {
	$unitwidth = $field[1];
    }
    elsif ($field[0] eq "sizescale") {
	$sizescale = $field[1];
    }
}
close(DESC);
$filename = "";
$lineno = 0;
} # end of read_DESC_file

# read the encoding file
sub read_encoding_file {

    my $sys_opt_e = $groff_sys_fontdir . "/devps/" . $opt_e;
    open(ENCODING, $opt_e) || open(ENCODING, $sys_opt_e) ||
	croak("cannot open '$opt_e' nor '$sys_opt_e': $!");
    while (<ENCODING>) {
	next if /^#/;
	chop;
	my @field = split(' ');
	next if $#field < 0;
	if ($#field == 1) {
	    if ($field[1] >= 0) {
		if ($iscidfont) {
		    # Convert $field[0] (glyphname) in the encoding file to the cid.
		    # This is because the CID-keyed font AFM file gives "N cid"
		    # instead of "N name".
		    next unless defined (my $cid = glyphname_to_cid($field[0]));
		    $field[0] = $cid;
		}
		next unless defined $width{$field[0]}; # xxxxx
		if ($opt_Ncid) {
		    my $n = $field[0];
		    if (defined $encoding[$n] && $encoding[$n] ne $n) {
			say STDERR "overwriting1 \$encoding[$n]: $encoding[$n] => $n";
		    }
		    $encoding[$field[0]] = $field[0];
		} else {
		    $encoding[$field[1]] = $field[0];
		}
		$in_encoding{$field[0]} = 1;
	    }
	}
    }
    close(ENCODING);
} # end of read_encoding_file


sub glyphname_to_cid {
    my $name = shift;
    my $uv = $AGL_to_unicode{$name};
    unless (defined $uv) {
	if ($name =~ /^cid0*(\d+)$/) {
	    return $1;
	}
	warn "$program_name: $name is not defined in \%AGL_to_unicode.\n"
	    if $debug;
	return undef;
    }
    unicode_to_cid($uv);
}


sub unicode_to_cid {
    my $uv = shift;
    my $gid = $otf->{'cmap'}->find_ms->{val}{hex $uv};
    unless (defined $gid) {
	warn "$program_name: unicode ($uv) is not defined in \$otf->cmap.\n"
	    if $debug;
	return undef;
    }
    if (my $subst = find_gsub($gid)) {
	$gid = $subst;
    }
    my $cid = $gid2cid->[$gid];
    unless (defined $cid) {
	warn "$program_name: gid ($gid) is not defined in \$otf->cff->{Charset}.\n"
	    if $debug;
	return undef;
    }
    $cid;
}


sub gid_to_glyphname {
    my $gid = shift;
    my %seen;
    my @psname;
    for my $u (@{$gid_to_utf8{$gid}}) {
	my @u = unpack "U*", $u;
	my $hex = join '_' => map sprintf("%04X", $_), @u;
	while (my ($name, $unicode) = each %AGL_to_unicode) {
	    push @psname, $name if defined $unicode && $unicode eq $hex;
	}
    }
    wantarray? @psname : $psname[0];
}


sub cid_to_glyphname {
    my $cid = shift;
    my $gid = $cid2gid->[$cid];
    gid_to_glyphname($gid);
}


# read the map file

our (%nmap, %map);

sub read_map_file {

if (open(MAP, $map)) {
    $filename = $map;
}
elsif (open(MAP, $sys_map)) {
    $filename = $sys_map;
}
else {
    croak("cannot open '$map' nor '$sys_map': $!");
}

while (<MAP>) {
    $lineno++;
    next if /^#/;
    chop;
    my @field = split(' ');
    next if $#field < 0;
    if ($#field == 1) {
	if ($field[1] eq "space") {
	    # The PostScript character "space" is automatically mapped
	    # to the groff character "space"; this is for grops.
	    whine("you are not allowed to map to the groff character"
		  . " 'space'");
	}
	elsif ($field[0] eq "space") {
	    whine("you are not allowed to map the PostScript character"
		  . " 'space'");
	}
	else {
	    my %seen;
	    my @utmp = grep defined && !$seen{$_}++, $AGL_to_unicode{$field[0]};
	    if ($iscidfont) {
		#next unless defined (my $cid = glyphname_to_cid($field[0]));
		next unless defined $utmp[0];
		next unless defined (my $cid = unicode_to_cid($utmp[0]));
		$field[0] = $cid;

		my $gid = $cid2gid->[$cid];
		for (grep defined, @{$gid_to_utf8{$gid}}) {
		    push @utmp, join '_', map { sprintf "%04X", $_ }
			unpack "n*", encode "UTF16-BE", $_;
		}
		my $u8 = pack 'U*', map hex($_), split '_', $utmp[0];
		@{$gid_to_utf8{$gid}} = grep !$seen{$_}++, $u8, @{$gid_to_utf8{$gid}};
	    }

	    $nmap{$field[0]} += 0;
	    $map{$field[0], $nmap{$field[0]}} = $field[1];
	    $nmap{$field[0]} += 1;

	    for my $utmp (@utmp) {
		foreach my $unicodepsname ("uni" . $utmp, "u" . $utmp) {
		    $nmap{$unicodepsname} += 0;
		    $map{$unicodepsname, $nmap{$unicodepsname}} = $field[1];
		    $nmap{$unicodepsname} += 1;
		}
	    }
	}
    }
}
close(MAP);
$filename = "";
$lineno = 0;
} # end of read_map_file

sub width_of {
    my $name = shift;
    if ($iscidfont) {
	if (defined (my $cid = glyphname_to_cid($name))) {
	    return $width{$cid};
	}
    }
    return $width{$name};
}


sub height_of {
    my $name = shift;
    if ($iscidfont) {
	if (defined (my $cid = glyphname_to_cid($name))) {
	    return $height{$cid};
	}
    }
    return $height{$name};
}


sub depth_of {
    my $name = shift;
    if ($iscidfont) {
	if (defined (my $cid = glyphname_to_cid($name))) {
	    return $depth{$cid};
	}
    }
    return $depth{$name};
}


# Don’t use the built‐in Adobe Glyph List.
sub do_names {

    my $duplicate_mappings_count = 0; # used only if $opt_q
    my %mapped;
    my $i = ($#encoding > 256) ? ($#encoding + 1) : 256;
    my $cmp = $iscidfont? sub { $a <=> $b } : sub { $a cmp $b };
    foreach my $ch (sort $cmp keys %width) {
	# add unencoded characters
	if (!$in_encoding{$ch}) {
	    if ($opt_Ncid) {
		my $n = $ch;
		if (defined $encoding[$n] && $encoding[$n] ne $n) {
		    say STDERR "overwriting2 \$encoding[$n]: $encoding[$n] => $n";
		}
		$encoding[$ch] = $ch;
	    } else {
		$encoding[$i] = $ch;
	    }
	    $in_encoding{$ch} = 1;
	    $i++;
	}
	if ($nmap{$ch}) {
	    for (my $j = 0; $j < $nmap{$ch}; $j++) {
		if (defined $mapped{$map{$ch, $j}}) {
		    if ($opt_q) {
			$duplicate_mappings_count++;
		    }
		    else {
		    my $entity_format = $iscidfont? "CID %d" : "AGL name '%s'";
		    print STDERR "$program_name: "
			 . sprintf($entity_format, $mapped{$map{$ch, $j}})
			 . " already mapped to"
			 . " groff name '$map{$ch, $j}'; ignoring "
			 . sprintf($entity_format, $ch)
			 . "\n";
		    }
		}
		else {
		    $mapped{$map{$ch, $j}} = $ch;
		}
	    }
	}
	elsif (!$iscidfont) {
	    my $u = "";		# the resulting groff glyph name
	    my $ucomp = "";	# Unicode string before decomposition
	    my $utmp = "";	# temporary value
	    my $component = "";
	    my $nv = 0;

	    # Step 1:
	    #   Drop all characters from the glyph name starting with the
	    #   first occurrence of a period (U+002E FULL STOP), if any.
	    #   ?? We avoid mapping of glyphs with periods, since they are
	    #   likely to be variant glyphs, leading to a 'many ps glyphs --
	    #   one groff glyph' conflict.
	    #
	    #   If multiple glyphs in the font represent the same character
	    #   in the Unicode standard, as do 'A' and 'A.swash', for example,
	    #   they can be differentiated by using the same base name with
	    #   different suffixes.  This suffix (the part of glyph name that
	    #   follows the first period) does not participate in the
	    #   computation of a character sequence.  It can be used by font
	    #   designers to indicate some characteristics of the glyph.  The
	    #   suffix may contain periods or any other permitted characters.
	    #   Small cap A, for example, could be named 'uni0041.sc' or
	    #   'A.sc'.

	    next if $ch =~ /\./;

	    # Step 2:
	    #  Split the remaining string into a sequence of components,
	    #  using the underscore character (U+005F LOW LINE) as the
	    #  delimiter.

	    while ($ch =~ /([^_]+)/g) {
		$component = $1;

		# Step 3:
		#   Map each component to a character string according to the
		#   procedure below:
		#
		#   * If the component is in the Adobe Glyph List, then map
		#     it to the corresponding character in that list.

		$utmp = $AGL_to_unicode{$component};
		if ($utmp) {
		    $utmp = "U+" . $utmp;
		}

		#   * Otherwise, if the component is of the form 'uni'
		#     (U+0075 U+006E U+0069) followed by a sequence of
		#     uppercase hexadecimal digits (0 .. 9, A .. F, i.e.,
		#     U+0030 .. U+0039, U+0041 .. U+0046), the length of
		#     that sequence is a multiple of four, and each group of
		#     four digits represents a number in the set {0x0000 ..
		#     0xD7FF, 0xE000 .. 0xFFFF}, then interpret each such
		#     number as a Unicode scalar value and map the component
		#     to the string made of those scalar values.

		elsif ($component =~ /^uni([0-9A-F]{4})+$/) {
		    while ($component =~ /([0-9A-F]{4})/g) {
			$nv = hex("0x" . $1);
			if ($nv <= 0xD7FF || $nv >= 0xE000) {
			    $utmp .= "U+" . $1;
			}
			else {
			    $utmp = "";
			    last;
			}
		    }
		}

		#   * Otherwise, if the component is of the form 'u' (U+0075)
		#     followed by a sequence of four to six uppercase
		#     hexadecimal digits {0 .. 9, A .. F} (U+0030 .. U+0039,
		#     U+0041 .. U+0046), and those digits represent a number
		#     in {0x0000 .. 0xD7FF, 0xE000 .. 0x10FFFF}, then
		#     interpret this number as a Unicode scalar value and map
		#     the component to the string made of this scalar value.

		elsif ($component =~ /^u([0-9A-F]{4,6})$/) {
		    $nv = hex("0x" . $1);
		    if ($nv <= 0xD7FF || ($nv >= 0xE000 && $nv <= 0x10FFFF)) {
			$utmp = "U+" . $1;
		    }
		}

		# Finally, concatenate those strings; the result is the
		# character string to which the glyph name is mapped.

		$ucomp .= $utmp if $utmp;
	    }

	    # Unicode decomposition
	    while ($ucomp =~ /([0-9A-F]{4,6})/g) {
		$component = $1;
		$utmp = $unicode_decomposed{$component};
		$u .= "_" . ($utmp ? $utmp : $component);
	    }
	    $u =~ s/^_/u/;
	    if ($u) {
		if (defined $mapped{$u}) {
		    # Don't whine about duplicates that exist to
		    # preserve round-trip conversions; thanks to James
		    # Cloos for pointing this out.
		    if (!(($mapped{$u} eq 'Delta' and ($ch eq 'uni0394'))
			 or ($mapped{$u} eq 'mu' and ($ch eq 'uni03BC'))
			 or ($mapped{$u} eq 'uni03A9' and ($ch eq 'uni2126')))) {
			whine("both $mapped{$u} and $ch map to $u");
		    }
		}
		else {
		    $mapped{$u} = $ch;
		}
		$nmap{$ch} += 1;
		$map{$ch, "0"} = $u;
	    }
	}
	else { # if ($iscidfont) {
	    my $cid = $ch;
	    my $gid = $cid2gid->[$cid];
	    if ($cid == $cid_space) {
		$nmap{$cid} += 0;
		$map{$cid, $nmap{$cid}} = "space";
		$nmap{$cid} += 1;
	    }
	    for my $u (@{$gid_to_utf8{$gid}}) {
		my @u = unpack "U*", $u;
		my $hex = join '_' => map sprintf("%04X", $_), @u;
		$nmap{$cid} += 0;
		$map{$cid, $nmap{$cid}} = 'u'.$hex;
		$nmap{$cid} += 1;
		if (my $dhex = $unicode_decomposed{$hex}) {
		    $nmap{$cid} += 0;
		    $map{$cid, $nmap{$cid}} = 'u'.$dhex;
		    $nmap{$cid} += 1;
		}
	    }
	}
    }
} # do_names


# Check explicitly for groff's standard ligatures -- many afm files don't
# have proper 'L' entries.

sub do_ligatures {

if ($iscidfont) {
    my $option = $ot_feature{liga}; # // '*,*,liga';
    my $liga = gsub($otf, grep defined, ot_feature($otf, 'GSUB', $option));
    for my $k (keys %$liga) {
        my @list;
        for my $gid ($k, @{$liga->{$k}}) {
            next unless my @glyphname = gid_to_glyphname($gid);
            warn "$program_name: $gid => [@glyphname]: not uniq\n" unless @glyphname == 1;
            push @list, $glyphname[0] if @glyphname;
        }
        $ligatures{$list[0]} = join ' ', @list if @list;
    }
}

my %default_ligatures = (
  "fi", "f i",
  "fl", "f l",
  "ff", "f f",
  "ffi", "ff i",
  "ffl", "ff l",
);

foreach my $lig (sort keys %default_ligatures) {
    if (defined $width{$lig} && !defined $ligatures{$lig}) {
	$ligatures{$lig} = $default_ligatures{$lig};
    }
}
} # do_ligatures

# print it all out
sub print_groff_font {

    $italic_angle = $opt_a if $opt_a;

open(FONT, ">$outfile") ||
  croak("cannot open '$outfile' for writing: $!");
select(FONT);

my @options;

push @options, "-a $opt_a" if defined $opt_a;
push @options, "-c"        if defined $opt_c;
push @options, "-d $opt_d" if defined $opt_d;
push @options, "-e $opt_e" if defined $opt_e;
push @options, "-f $opt_f" if defined $opt_f;
push @options, "-i $opt_i" if defined $opt_i;
push @options, "-k"        if defined $opt_k;
push @options, "-m"        if defined $opt_m;
push @options, "-n"        if defined $opt_n;
push @options, "-o $opt_o" if defined $opt_o;
# Don't add $opt_q here; it is irrelevant to the generated file.
push @options, "-s"        if defined $opt_s;
push @options, "-v"        if defined $opt_v;
push @options, "-w $opt_w" if defined $opt_w;

push @options, "-D"        if defined $debug;
push @options, "-F $_"     for @ot_feature;
push @options, "-N"        if defined $opt_Ncid;
push @options, "-S"        if defined $skip_nonames;
push @options, "-V"        if defined $opt_vertical;

my $opts = join ' ', @options;

print("# generated by $output_version\n");
print("#   AFM file: $afmfile\n") if $afmfile;
print("#   OTF file: $otffile\n") if $otffile;
print("#   map file: $map\n");
print("#   with options \"$opts\"\n") if @options;
print("#\n");
print("#   $fullname\n") if defined $fullname;
print("#   $version\n") if defined $version;
print("#   $familyname\n") if defined $familyname;

if ($opt_c) {
    print("#\n");
    if (defined $notice || @comments) {
	print("# The AFM file contained the following comments.\n");
	print("#\n");
	print("#   $notice\n") if defined $notice;
	foreach my $comment (@comments) {
	    print("#   $comment\n");
	}
    }
    else {
	print("# The AFM file contained no comments.\n");
    }
}

print("\n");

my $name = $fontfile;
$name =~ s@.*/@@;

my $sw = 0;
$sw = conv($width{"space"}) if !$iscidfont && defined $width{"space"};
$sw = conv($width{$cid_space}) if $iscidfont && defined $width{$cid_space};
$sw = $space_width if ($space_width);

print("name $name\n");
print("internalname $psname\n") if $psname;
print("cidfont $characterset\n") if $iscidfont;
if ($otf) {
    print("opentype",
          @gsub_index ? " gsub=".join(',', @gsub_index) : (),
          @gpos_index ? " gpos=".join(',', @gpos_index) : (),
          "\n");
}
print("special\n") if $opt_s;
print("vertical\n") if $opt_vertical;
printf("slant %g\n", map { $opt_vertical ? -$_ : $_ } $italic_angle) if $italic_angle != 0;
printf("spacewidth %d\n", $sw) if $sw;

if ($opt_e) {
    my $e = $opt_e;
    $e =~ s@.*/@@;
    print("encoding $e\n");
}

if (!$opt_n && %ligatures) {
    print("ligatures");
    foreach my $lig (sort keys %ligatures) {
	print(" $lig");
    }
    print(" 0\n");
}

if (!$opt_k && $#kern1 >= 0) {
    print("\n");
    print("kernpairs\n");

    for (my $i = 0; $i <= $#kern1; $i++) {
	my $c1 = $kern1[$i];
	my $c2 = $kern2[$i];
	if (defined $nmap{$c1} && $nmap{$c1} != 0
	    && defined $nmap{$c2} && $nmap{$c2} != 0) {
	    for (my $j = 0; $j < $nmap{$c1}; $j++) {
		for (my $k = 0; $k < $nmap{$c2}; $k++) {
		    if ($kernx[$i] != 0) {
			printf("%s %s %d\n",
			       $map{$c1, $j},
			       $map{$c2, $k},
			       conv($kernx[$i]));
		    }
		}
	    }
	}
    }
}

my ($asc_boundary, $desc_boundary, $xheight, $slant);

# characters not shorter than asc_boundary are considered to have ascenders

$asc_boundary = 0;
#$asc_boundary = $height{"t"} if defined $height{"t"};
$asc_boundary = height_of("t") if defined height_of("t");
$asc_boundary -= 1;

# likewise for descenders

$desc_boundary = 0;
#$desc_boundary = $depth{"g"} if defined $depth{"g"};
#$desc_boundary = $depth{"j"} if defined $depth{"g"} && $depth{"j"} < $desc_boundary;
#$desc_boundary = $depth{"p"} if defined $depth{"p"} && $depth{"p"} < $desc_boundary;
#$desc_boundary = $depth{"q"} if defined $depth{"q"} && $depth{"q"} < $desc_boundary;
#$desc_boundary = $depth{"y"} if defined $depth{"y"} && $depth{"y"} < $desc_boundary;
$desc_boundary = min(grep defined, map depth_of($_), qw/g j p q y/);
$desc_boundary -= 1;

if (defined $height{"x"}) {
    #$xheight = $height{"x"};
    $xheight = height_of("x");
}
elsif (defined $height{"alpha"}) {
    #$xheight = $height{"alpha"};
    $xheight = height_of("alpha");
}
else {
    $xheight = 450;
}

$italic_angle = $italic_angle*3.14159265358979323846/180.0;
$slant = sin($italic_angle)/cos($italic_angle);
$slant = 0 if $slant < 0;

print("\n");
print("charset\n");
for (my $i = 0; $i <= $#encoding; $i++) {
    my $ch = $encoding[$i];
    next unless defined $ch;
    #if (defined $ch && $ch ne "" && $ch ne "space") {
    if (defined $ch && $ch ne "" &&
	# $ch ne "space"
	($iscidfont || $ch ne "space")
    ) {
	#$map{$ch, "0"} = "---" if !defined $nmap{$ch} || $nmap{$ch} == 0;
	if (!defined $nmap{$ch} || $nmap{$ch} == 0) {
	    $map{$ch, "0"} = "---";
	    next if $skip_nonames;
	}
	my $type = 0;
	my $h = $height{$ch};
	$h = 0 if $h < 0;
	my $d = $depth{$ch};
	$d = 0 if $d < 0;
	$type = 1 if $d >= $desc_boundary;
	$type += 2 if $h >= $asc_boundary;
	printf("%s\t%d", $map{$ch, "0"}, conv($width{$ch}));
	my $italic_correction = 0;
	my $left_math_fit = 0;
	my $subscript_correction = 0;
	if (defined $opt_i) {
	    $italic_correction = $right_side_bearing{$ch} + $opt_i;
	    $italic_correction = 0 if $italic_correction < 0;
	    $subscript_correction = $slant * $xheight * .8;
	    $subscript_correction = $italic_correction if
		$subscript_correction > $italic_correction;
	    $left_math_fit = $left_side_bearing{$ch} + $opt_i;
	    if (defined $opt_m) {
		$left_math_fit = 0 if $left_math_fit < 0;
	    }
	}
	if (defined $italic_correction{$ch}) {
	    $italic_correction = $italic_correction{$ch};
	}
	if (defined $left_italic_correction{$ch}) {
	    $left_math_fit = $left_italic_correction{$ch};
	}
	if (defined $subscript_correction{$ch}) {
	    $subscript_correction = $subscript_correction{$ch};
	}
	if ($opt_vertical) {
	    ($italic_correction, $left_math_fit) =
		($left_math_fit, $italic_correction);
	}
	if ($subscript_correction != 0) {
	    printf(",%d,%d", conv($h), conv($d));
	    printf(",%d,%d,%d", conv($italic_correction),
		   conv($left_math_fit),
		   conv($subscript_correction));
	}
	elsif ($left_math_fit != 0) {
	    printf(",%d,%d", conv($h), conv($d));
	    printf(",%d,%d", conv($italic_correction),
		   conv($left_math_fit));
	}
	elsif ($italic_correction != 0) {
	    printf(",%d,%d", conv($h), conv($d));
	    printf(",%d", conv($italic_correction));
	}
	elsif ($d != 0) {
	    printf(",%d,%d", conv($h), conv($d));
	}
	else {
	    # always put the height in to stop groff guessing
	    printf(",%d", conv($h));
	}
	printf("\t%d", $type);
	printf("\t%d\t%s", $i, $ch);
	my @copts;
	my $u8;
	if ($iscidfont) {
	    # $ch is cid
	    my $cid = $ch;
	    my $gid = $cid2gid->[$cid]; # xxxxx
	    push @copts, "gid=$gid" if $gid != $cid;
	    if (my $hint = $gid_hint{$gid}) {
		push @copts, $hint;
	    }
	    if ($gpos) {
		while (my ($key, $value) = each %{$gpos->{$gid}}) {
		    push @copts, "$key=$value"
			#if $key =~ /^[XY](Placement|Advance)$/ && defined $value;
			if $key =~ /^[XY]Placement$/ && defined $value;
		}
	    }
	    ($u8) = @{$gid_to_utf8{$gid}};
	} else {
	    if (my $unicode = $AGL_to_unicode{$ch}) {
		$u8 = pack "U*", map hex($_), split '_', $unicode;
	    }
	}

	if ($u8) {
	    if (length $map{$ch, "0"} == 1 && $map{$ch, "0"} eq $u8) {
		0 and do {
		    say STDERR "# \$map{$ch, '$_'} = ", $map{$ch, $_} for 0;
		};
	    } elsif ($map{$ch, "0"} =~ /^u([\dA-F_]+)$/) {
		;
	    } else {
		0 and do {
		    for (0 .. $nmap{$ch} - 1) {
			say STDERR "# \$map{$ch, '$_'} = ", $map{$ch, $_};
		    }
		};

		# If the Unicode value cannot be obtained from the glyph
		# name, or the Unicode value is ambiguous, [1] put
		# unicode=xxxx (utf16) in the comment.

		# [1] For glyphs that have multiple names (uXXXX), the
		# resulting Unicode value is ambiguous.

		my $u16 = join '_', map { sprintf "%04X", $_ }
		    unpack "n*", encode "UTF16-BE", $u8;
		push @copts, "unicode=$u16";
	    }
	}
	if (@copts) {
	    print "\t-- @copts";
	}
	printf("\n");
	if (defined $nmap{$ch}) {
	    for (my $j = 1; $j < $nmap{$ch}; $j++) {
		printf("%s\t\"\n", $map{$ch, $j});
	    }
	}
    }
    if (!$iscidfont &&
	defined $ch && $ch eq "space" && defined $width{"space"}) {
	printf("space\t%d\t0\t%d\tspace\n", conv($width{"space"}), $i);
    }
}
} # end of print_groff_font

sub print_mini_afm {
    select(STDOUT);

    # 5004.AFM_Spec.pdf

    my $metricssets =
	@{$otf->{'hmtx'}{'advance'}} > 0 && @{$otf->{'vmtx'}{'advance'}} > 0 ? 2 :
	@{$otf->{'vmtx'}{'advance'}} > 0 ? 1 :
	@{$otf->{'hmtx'}{'advance'}} > 0 ? 0 : -1;
    die "$program_name: cannot support MetricsSets $metricssets\n"
	unless $metricssets == 2;
    my $startdirection = 2;
    my $isbasefont = 1;

    #push @comments, "Copyright 2026 Adobe Systems Incorporated. All Rights Reserved.";
    push @comments, "Creation Date: " . scalar localtime;

    my $cff = $otf->{'CFF '};
    print "StartFontMetrics 4.1\n";
    print "Comment $_\n" for @comments;
    print "MetricsSets $_\n" for $metricssets;
    print "FontName $_\n" for $psname;
    print "Weight $_\n" for grep defined, $weight;
    print "FontBBox @$_\n" for grep defined, $fontbbox;
    print "Version $_\n" for $version;
    print "Notice $_\n" for $notice;
    print "CharacterSet $_\n" for $characterset;
    print "Characters $_\n" for scalar @{$gid2cid};
    print "IsBaseFont $_\n" for $isbasefont ? "true" : "false";
    print "IsCIDFont $_\n" for $iscidfont ? "true" : "false";
    print "StartDirection $_\n" for $startdirection;
    for my $name (qw/UnderlinePosition UnderlineThickness ItalicAngle IsFixedPitch/) {
	my $value = $cff->TopDICT->{$name} // $cff->TopDICT->{lcfirst $name};
	$value = $value ? 'true' : 'false' if $name =~ /^is/i;
	print "$name $value\n";
    }
    print "EndDirection\n";
    print "StartCharMetrics $_\n" for scalar @{$gid2cid};
    for my $gid (0 .. $#{$gid2cid}) {
	my $u = $gid_to_utf8{$gid};
	my @c = @$u if ref $u;
	my $c = @c ? unpack 'n*', encode 'UTF16-BE', $c[0] : -1;
	my $cid = $gid2cid->[$gid];
	my $n = $cid;
	my $llx = -$left_side_bearing{$n};
	my $lly = -$depth{$n};
	my $w = $width{$n};
	my $urx = $width{$n} + $right_side_bearing{$n};
	my $ury = $height{$n};
	print join " ", map "$_ ;", "C $c", "W0X $w", "N $n", "B $llx $lly $urx $ury";
	print "\n";
    }
    print "EndCharMetrics\n";
    print "EndFontMetrics\n";

} # end of print_mini_afm


sub conv {
    $_[0]*$unitwidth*$resolution/(72*1000*$sizescale)
      + ($_[0] < 0 ? -.5 : .5);
}

sub find_gsub {
    my ($gid, $hint) = @_;
    if ($gsub) {
	my $start = $gid;
	while (my $subst = $gsub->{$gid}) {
	    if ($subst == $start) {
		warn "gsub $start seems looping." if $debug;
		last;
	    }
	    $gid = $subst;
	}
	if ($gid != $start) {
	    $gid_hint{$gid} = $hint if $hint;
	    return $gid;
	}
    }
    undef;
}


sub gsub {
    my $otf = shift;
    my $gsub;
    for my $index (grep defined, @_) {
	my $value = $otf->{GSUB}{LOOKUP}[$index];
	if ($value->{TYPE} == 1) {
	    for (@{$value->{SUB}}) {
		while (my ($gid, $i) = each %{$_->{COVERAGE}{val}}) {
		    $gsub->{$gid} = $_->{RULES}[$i][0]{ACTION}[0];
		}
	    }
	} elsif ($value->{TYPE} == 4) {
	    for (@{$value->{SUB}}) {
		while (my ($gid, $i) = each %{$_->{COVERAGE}{val}}) {
		    for (@{$_->{RULES}[$i]}) {
			$gsub->{join $;, @{$_->{ACTION}}} =
			    [ $gid + 0, @{$_->{MATCH}} ];
		    }
		}
	    }
	} else {
	    die "gsub: unknown \$value->{TYPE}: $value->{TYPE}";
	}
    }
    $gsub;
}


sub gpos {
    my $otf = shift;
    my $gpos;
    for my $index (grep defined, @_) {
	my $value = $otf->{GPOS}{LOOKUP}[$index];
	if ($value->{TYPE} == 1) {
	    # Lookup type 1 subtable: single adjustment positioning
	    for (@{$value->{SUB}}) {
		while (my ($gid, $i) = each %{$_->{COVERAGE}{val}}) {
		    $gpos->{$gid} = $_->{RULES}[$i][0]{ACTION}[0];
		}
	    }
	} elsif ($value->{TYPE} == 2) {
	    # Lookup type 2 subtable: pair adjustment positioning
	    for (@{$value->{SUB}}) {
		my @gid;
		while (my ($gid, $i) = each %{$_->{COVERAGE}{val}}) {
		    $gid[$i] = $gid;
		}
		my $MATCH_TYPE  = $_->{MATCH_TYPE};
		my $ACTION_TYPE = $_->{ACTION_TYPE};
		if ($MATCH_TYPE eq 'g' && $ACTION_TYPE eq 'p') {
		    # $_->{FORMAT} = 1: Pair adjustment positioning
		    # MATCH_TYPE = 'g': A glyph array
		    # ACTION_TYPE = 'p': Pair adjustment
		    for my $i (0 ..  $#{$_->{RULES}}) {
			my $gid = $gid[$i];
			for my $j (0 ..  $#{$_->{RULES}[$i]}) {
			    my $gid2 = $_->{RULES}[$i][$j]{MATCH}[0];
			    $gpos->{$gid, $gid2} = $_->{RULES}[$i][$j]{ACTION}[0];
			}
		    }
		} elsif ($MATCH_TYPE eq 'c' && $ACTION_TYPE eq 'p') {
		    # $_->{FORMAT} = 2: Pair adjustment positioning
		    # MATCH_TYPE = 'c': An array of class values
		    # ACTION_TYPE = 'p': Pair adjustment
		    for my $gid (@gid) {
			my $c = $_->{CLASS}{val}{$gid};
			next unless defined $c;
			while (my ($gid2, $c2) = each %{$_->{MATCH}[0]{val}}) {
			    next unless $c2;
			    $gpos->{$gid, $gid2} = $_->{RULES}[$c][$c2]{ACTION}[0];
			}
		    }
		} else {
		    die "gpos: unknown \$_->{FORMAT}: $_->{FORMAT} in TYPE 2";
		}
	    }
	}
	else {
	    die "gpos: unknown \$value->{TYPE}: $value->{TYPE} (index: $index)";
	}
    }
    $gpos;
}


sub ot_feature {
    my ($otf, $tag, $option) = @_;
    return undef unless $otf;
    return undef unless $option;

    my ($script, $lang, $wanted) = split /,\s*/, $option;
    return undef unless defined $script && defined $lang && defined $wanted;

    unless (ref $otf->{$tag} && $otf->{$tag}->read) {
	warn "$program_name: can't read $tag table; ignored\n";
	return undef;
    }

    # filter /$script/,
    my %seen;
    my @script = grep !$seen{$_}++,
	grep $script eq '*' || /^$script\s*$/,
	keys %{$otf->{$tag}{SCRIPTS}};

    # filter /lang/, @script
    my @lang;
    my @features = map {
	my $languages = $otf->{$tag}{SCRIPTS}{$_};
	@lang = grep !$seen{$_}++, @{$languages->{LANG_TAGS}};
	@lang = 'DFLT' unless @lang;
	map @{$_->{FEATURES}},
	    map $languages->{$_} || $languages->{DEFAULT},
	    grep $lang eq '*' || /^$lang\s*$/i,
	    @lang;
    } @script;

    # filter  /wanted/, @features
    %seen = ();
    my @index = grep !$seen{$_}++,
	map @{ $otf->{$tag}{FEATURES}{$_}{LOOKUPS} },
	grep /$wanted/,
	@features;

    1 and printf STDERR "$tag: script => '%s', lang => '%s', features => '%s': %s\n",
	$script, $lang, $wanted, join ', ', @index
	if @index;

    @index;
}


1;

__END__

=encoding utf-8

=head1 NAME

App::otftodit - It's new $module

=head1 SYNOPSIS

    use App::otftodit;

=head1 DESCRIPTION

App::otftodit is ...

=head1 LICENSE

Copyright (C) KUBO, Koichi.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

KUBO, Koichi E<lt>k@obuk.orgE<gt>

=cut

# Local Variables:
# fill-column: 72
# mode: CPerl
# End:
# vim: set cindent noexpandtab shiftwidth=4 softtabstop=4 textwidth=72:
