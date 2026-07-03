package App::otftodit::Plot;

=head1 NAME

App::otftodit::Plot - 

=head1 SYNOPSYS

=head1 DESCRIPTION

=cut

use strict;
use warnings;
use Carp;
use List::Util qw(max min);
use parent 'App::otftodit::BBox';
use Imager;
use Imager::Color;

use Class::Tiny qw(M image color);

sub init {
    my ($self) = @_;
    $self->SUPER::init;
    $self->M([ 0.5, 0, 0, -0.5, 0, 0 ]);
    my ($x1, $y1) = $self->mmul([ -100, 1000 ]);
    my ($x2, $y2) = $self->mmul([ 1100, -300 ]);
    my ($xmin, $ymin) = (min($x1, $x2), min($y1, $y2));
    my ($xmax, $ymax) = (max($x1, $x2), max($y1, $y2));
    my ($xsize, $ysize) = ($xmax - $xmin, $ymax - $ymin);
    $self->M([ @{$self->M}[0..3], -$xmin, -$ymin ]);
    $self->image(Imager->new(xsize => $xmax - $xmin, ysize => $ymax - $ymin));
    $self->color(Imager::Color->new(255, 255, 255));
    $self;
}


sub mmul {
    my $self = shift;
    my ($x, $y) = @{ scalar shift @_};
    my ($a, $b, $c, $d, $e, $f) = @_ == 0 ? @{$self->M} : ref $_[0] ? @{$_[0]} : @_;
    ($a * $x + $c * $y + $e, $b * $x + $d * $y + $f);
}


sub closepath {
    my ($self) = @_;
    $self->SUPER::closepath;
    if (@{$self->points} >= 2) {
	$self->image->polyline(
	    points => [ map [ $self->mmul($self->points->[$_]) ], -1, 0 ],
	    color => $self->color,
	);
    }
}

sub moveto {
    my $self = shift;
    $self->SUPER::moveto(@_);
    if (@{$self->{points}} >= 2) {
	my $p = pop @{$self->points};
	$self->_bbox;
	push @{$self->points}, $p;
    }
}

sub lineto {
    my $self = shift;
    my $i = $#{$self->points};
    $self->SUPER::lineto(@_);
    my $j = $#{$self->points};
    $self->image->polyline(
	points => [ map [ $self->mmul($self->points->[$_]) ], $i .. $j ],
	color => $self->color,
    );
}

sub curveto {
    my $self = shift;
    my $i = $#{$self->points};
    $self->SUPER::curveto(@_);
    my $j = $#{$self->points};
    $self->image->polyline(
	points => [ map [ $self->mmul($self->points->[$_]) ], $i .. $j ],
	color => $self->color,
    );
}

sub _bbox {
    my $self = shift;
    $self->closepath;
    $self->SUPER::_bbox;
}

1;

__END__
