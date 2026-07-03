package App::otftodit::BBox;

=head1 NAME

App::otftodit::BBox - 

=head1 SYNOPSYS

=head1 DESCRIPTION

=cut

use strict;
use warnings;
use Carp;
use Math::Bezier::Convert qw(cubic_to_lines);
use List::Util qw(max min);
use Font::TTF::CFF_;

sub new {
    my $class = shift;
    my $self = bless { @_ }, $class;
    $self->init;
}

use Class::Tiny qw(points llx lly urx ury);
use Class::Tiny qw(high_resolution bezier_extrema);

sub init {
    my ($self) = @_;
    $self->install;
    $self->points([]);
    $self->llx(undef);
    $self->lly(undef);
    $self->urx(undef);
    $self->ury(undef);
    $self;
}

sub closepath {
    my ($self) = @_;
    #confess "no points" unless ref $self->points;
}

sub moveto {
    my ($self, $dx, $dy) = @_;
    #confess "no points" unless ref $self->points;
    my ($x, $y) = @{$self->points->[-1] // [ 0, 0 ]};
    if (@{$self->points} == 1 && $x == 0 && $y == 0) {
	pop @{$self->points};
    }
    push @{$self->points}, [ $x + $dx, $y + $dy ];
}

sub lineto {
    my ($self, $dx, $dy) = @_;
    #confess "no points" unless ref $self->points;
    my ($x, $y) = @{$self->points->[-1]};
    push @{$self->points}, [ $x + $dx, $y + $dy ];
}

sub curveto {
    my ($self, $dx1, $dy1, $dx2, $dy2, $dx3, $dy3) = @_;
    #confess "no points" unless ref $self->points;
    my ($x, $y) = @{$self->points->[-1]};
    my @control = ($x, $y);
    push @control, ($control[-2] + $dx1, $control[-1] + $dy1);
    push @control, ($control[-2] + $dx2, $control[-1] + $dy2);
    push @control, ($control[-2] + $dx3, $control[-1] + $dy3);
    if ($self->bezier_extrema) {
	my ($min_x, $max_x) = get_bezier_extrema(@control[0, 2, 4, 6]);
	my ($min_y, $max_y) = get_bezier_extrema(@control[1, 3, 5, 7]);
	push @{$self->points}, [$min_x, $min_y], [$max_x, $max_y], [ @control[6, 7] ];
    }
    else {
	my @lines = cubic_to_lines(@control);
	push @{$self->points}, [ splice @lines, 0, 2 ] while @lines;
    }
}


# get_bezier_extrema - calculates the extrema points (potential BBox
# bounds) of a cubic Bezier curve along a single axis (X or Y)
# efficiently.

sub get_bezier_extrema {
    my ($p0, $p1, $p2, $p3) = @_;

    my @candidates;# = ($p0, $p3);

    # Compute coefficients for the derivative equation: at^2 + bt + c = 0
    my $a = 3 * ($p3 - 3 * $p2 + 3 * $p1 - $p0);
    my $b = 6 * ($p2 - 2 * $p1 + $p0);
    my $c = 3 * ($p1 - $p0);

    # 1. Solve as a quadratic equation (a != 0)
    if (abs($a) > 1e-12) {
        my $discriminant = $b * $b - 4 * $a * $c;
        if ($discriminant >= 0) {
            my $sqrt_d = sqrt($discriminant);
            my $t1 = (-$b + $sqrt_d) / (2 * $a);
            if ($t1 > 0 && $t1 < 1) {
                push @candidates, (1-$t1)**3 * $p0 + 3*(1-$t1)**2 * $t1 * $p1 + 3*(1-$t1) * $t1**2 * $p2 + $t1**3 * $p3;
            }
            my $t2 = (-$b - $sqrt_d) / (2 * $a);
            if ($t2 > 0 && $t2 < 1) {
                push @candidates, (1-$t2)**3 * $p0 + 3*(1-$t2)**2 * $t2 * $p1 + 3*(1-$t2) * $t2**2 * $p2 + $t2**3 * $p3;
            }
        }
    }
    # 2. Special case where it becomes a linear equation (a == 0, b != 0)
    elsif (abs($b) > 1e-12) {
        my $t = -$c / $b;
        if ($t > 0 && $t < 1) {
            push @candidates, (1-$t)**3 * $p0 + 3*(1-$t)**2 * $t * $p1 + 3*(1-$t) * $t**2 * $p2 + $t**3 * $p3;
        }
    }

    return (min(@candidates), max(@candidates));
}

sub _bbox {
    my $self = shift;
    if ($self->points && @{$self->points}) {
	my @points = grep defined $_->[0] && defined $_->[1],
	    @{$self->points}, [ $self->llx, $self->lly ], [ $self->urx, $self->ury ];
	$self->llx(min map int($_->[0] + 0.5), @points);
	$self->lly(min map int($_->[1] + 0.5), @points);
	$self->urx(max map int($_->[0] + 0.5), @points);
	$self->ury(max map int($_->[1] + 0.5), @points);
	$self->points([]);
    }
}

sub bbox {
    my $self = shift;
    $self->_bbox;
    if (@_) {
	my @bbox = (@_ == 1 && ref $_[0])? @{$_[0]} : @_;
	confess "bbox(llx, lly, urx, ury)" unless @bbox == 4;
	$self->llx($bbox[0]);
	$self->lly($bbox[1]);
	$self->urx($bbox[2]);
	$self->ury($bbox[3]);
    }
    my @bbox = ($self->llx, $self->lly, $self->urx, $self->ury);
    wantarray? @bbox : \@bbox;
}

sub plot_ {
    my ($self, $gid, $pen) = @_;

    $pen and $pen->moveto(0, 0);

    $self->{transient_array} = [];
    $self->{v}  = [];
    $self->{w}  = undef;
    $self->{hs} = [];
    $self->{vs} = [];

    my $fdindex = $self->FDSelect($gid);
    $self->FontDICT($fdindex);
    my $pdict = $self->PrivateDICT();

    my $class = 'CharStrings_INDEX';
    my $code = $self->$class->data($gid);
    $self->_plot({ class => $class, id => $gid }, $code, $pen);
}

sub _plot_ {
    my $self = shift;
    my $f = shift if @_ && ref $_[0] eq 'HASH';
    my $code = shift;
    my $pen = shift;

    my $packed_code;
    unless (ref $code eq 'ARRAY') {
	$packed_code = $code;
	$code = [ unpack "C*", $packed_code ];
    }

    while (@{$code} > 0) {
	my $c = shift @{$code};

	# 32 - 246: result = v–139
	if ($c >= 32 && $c <= 246) {
	    my $int = $c - 139;
	    push @{$self->{v}}, $int;
	}

	# 247 - 250: with next byte, w, result = (v–247)*256+w+108
	elsif ($c >= 247 && $c <= 250) {
	    my $c1 = shift @{$code};
	    my $int = ($c - 247) * 256 + $c1 + 108;
	    push @{$self->{v}}, $int;
	}
	# 251 - 254: with next byte, w, result = –[(v–251)*256]–w–108.
	elsif ($c >= 251 && $c <= 254) {
	    my $c1 = shift @{$code};
	    my $int = -($c - 251) * 256 - $c1 - 108;
	    push @{$self->{v}}, $int;
	}
	# 255: next 4 bytes interpreted as a 32-bit two's-complement number
	elsif ($c == 255) {
	    my ($c1, $c2, $c3, $c4) = splice @{$code}, 0, 4;
	    my $int = $c1 << 24 | $c2 << 16 | $c3 << 8 | $c4;
	    # 16-bit signed integer with 16 bits of fraction.
	    $int = -((~$int & 0xffff_ffff) + 1) if $int & 0x8000_0000;
	    $int /= 1 << 16;
	    push @{$self->{v}}, $int;
	}

	# 28: following 2 bytes interpreted as a 16-bit two's complement number
	elsif ($c == 28) {
	    my ($c1, $c2) = splice @{$code}, 0, 2;
	    my $int = $c1 << 8 | $c2;
	    $int = -((~$int & 0xffff) + 1) if $int & 0x8000;
	    push @{$self->{v}}, $int;
	}

	# 0 - 11: operators
	elsif ($c == 1) {
	    # |- y dy {dya dyb}* hstem (1) |-
	    #&$hstem unless @{$self->{hs}};
	    unless (@{$self->{hs}}) {
		#my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
		my $r = scalar @{$self->{v}} % 2;
		my $q = int scalar @{$self->{v}} / 2;
		push @{$self->{hs}}, splice @{$self->{v}}, -($q * 2);
		$self->{w} = pop @{$self->{v}} unless defined $self->{w} && $r;
	    }
	    $self->{v} = []; # clear
	}

	elsif ($c == 3) {
	    # |- x dx {dxa dxb}* vstem (3) |-
	    #&$vstem unless @{$self->{vs}};
	    unless (@{$self->{vs}}) {
		#my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
		my $r = scalar @{$self->{v}} % 2;
		my $q = int scalar @{$self->{v}} / 2;
		push @{$self->{vs}}, splice @{$self->{v}}, -($q * 2);
		$self->{w} = pop @{$self->{v}} unless defined $self->{w} && $r;
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 4) {
	    # |- dy1 vmoveto (4) |-
	    my ($dy1) = shift @{$self->{v}};
	    $pen and $pen->moveto(0, $dy1);
	    $self->{v} = []; # clear
	}
	elsif ($c == 5) {
	    # |- {dxa dya}+ rlineto (5) |-
	    while (@{$self->{v}} >= 2) {
		my ($dxa, $dya) = splice @{$self->{v}}, 0, 2;
		$pen and $pen->lineto($dxa, $dya);
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 6) {
	    # |- dx1 {dya dxb}* hlineto (6) |-
	    # |- {dxa dyb}+ hlineto (6) |-
	    #my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
	    my $r = scalar @{$self->{v}} % 2;
	    #my $q = int scalar @{$self->{v}} / 2;
	    if ($r == 1) {
		my $dx1 = shift @{$self->{v}};
		$pen and $pen->lineto($dx1, 0);
		while (@{$self->{v}} > 0) {
		    my ($dya, $dxb) = splice @{$self->{v}}, 0, 2;
		    $pen and $pen->lineto(0, $dya);
		    $pen and $pen->lineto($dxb, 0);
		}
	    } else {
		while (@{$self->{v}} > 0) {
		    my ($dxa, $dyb) = splice @{$self->{v}}, 0, 2;
		    $pen and $pen->lineto($dxa, 0);
		    $pen and $pen->lineto(0, $dyb);
		}
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 7) {
	    # |- dy1 {dxa dyb}* vlineto (7) |-
	    # |- {dya dxb}+ vlineto (7) |-
	    #my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
	    my $r = scalar @{$self->{v}} % 2;
	    #my $q = int scalar @{$self->{v}} / 2;
	    if ($r == 1) {
		my $dy1 = shift @{$self->{v}};
		$pen and $pen->lineto(0, $dy1);
		while (@{$self->{v}} > 0) {
		    my ($dxa, $dyb) = splice @{$self->{v}}, 0, 2;
		    $pen and $pen->lineto($dxa, 0);
		    $pen and $pen->lineto(0, $dyb);
		}
	    } else {
		while (@{$self->{v}} > 0) {
		    my ($dya, $dxb) = splice @{$self->{v}}, 0, 2;
		    $pen and $pen->lineto(0, $dya);
		    $pen and $pen->lineto($dxb, 0);
		}
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 8) {
	    # |- {dxa dya dxb dyb dxc dyc}+ rrcurveto (8) |-
	    while (@{$self->{v}} >= 6) {
		my ($dxa, $dya, $dxb, $dyb, $dxc, $dyc) = splice @{$self->{v}}, 0, 6;
		$pen and $pen->curveto($dxa, $dya, $dxb, $dyb, $dxc, $dyc);
	    }
	    $self->{v} = []; # clear
	}

	elsif ($c == 10) {
	    # subr# callsubr (10) –
	    my $subr = pop @{$self->{v}};
	    my $class = 'LocalSubr_INDEX';
	    my $cs = $self->$class;
	    my $index = $subr + $cs->bias;
	    my $code = $cs->data($index);
	    $self->_plot({ %$f, class => $class, id => $index }, $code, $pen);
	}
	elsif ($c == 11) {
	    # – return (11) –
	    #last;
	}
	elsif ($c == 12) {
	    #last unless @$code >= 1;
	    my $c2 = shift @$code;

	    if (0) {
	    }

	    elsif ($c2 == 3) {
		# num1 num2 and (12 3) 1_or_0
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		my $bool = $num1 && $num2;
		push @{$self->{v}}, $bool;
	    }
	    elsif ($c2 == 4) {
		# num1 num2 or (12 4) 1_or_0
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		my $bool = $num1 || $num2;
		push @{$self->{v}}, $bool;
	    }
	    elsif ($c2 == 5) {
		# num1 not (12 5) 1_or_0
		my $num1 = pop @{$self->{v}};
		my $bool = !$num1;
		push @{$self->{v}}, $bool;
	    }

	    elsif ($c2 == 9) {
		# num abs (12 9) num2
		my $num = pop @{$self->{v}};
		my $num2 = $num < 0 ? -$num : $num;
		push @{$self->{v}}, $num2;
	    }
	    elsif ($c2 == 10) {
		# num1 num2 add (12 10) sum
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		my $sum = $num1 + $num2;
		push @{$self->{v}}, $sum;
	    }
	    elsif ($c2 == 11) {
		# num1 num2 sub (12 11) difference
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		my $difference = $num1 - $num2;
		push @{$self->{v}}, $difference;
	    }
	    elsif ($c2 == 12) {
		# num1 num2 div (12 12) quotient
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		my $quotient = $num1 / $num2;
		push @{$self->{v}}, $quotient;
	    }

	    elsif ($c2 == 14) {
		# num neg (12 14) num2
		my $num = pop @{$self->{v}};
		my $num2 = -$num;
		push @{$self->{v}}, $num2;
	    }
	    elsif ($c2 == 15) {
		# num1 num2 eq (12 15) 1_or_0
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		my $bool = $num1 == $num2;
		push @{$self->{v}}, $bool;
	    }

	    elsif ($c2 == 18) {
		# num drop (12 18)

		# removes the top element num from the Type 2 argument
		# stack.
		my $num = pop @{$self->{v}};
	    }

	    elsif ($c2 == 20) {
		# The storage operators utilize a transient array and
		# provide facilities for storing and retrieving transient
		# array data. The transient array provides non-persistent
		# storage for intermediate values. There is no provision
		# to initialize this array, except explicitly using the
		# put operator, and values stored in the array do not
		# persist beyond the scope of rendering an individual
		# character. The number of elements in the transient array
		# is specified in Appendix B, “Type 2 Charstring
		# Implementation Limits”.
		#     val i put (12 20)
		# stores val into the transient array at the location given by i.

		my $i = pop @{$self->{v}};
		my $val = pop @{$self->{v}};
		$self->{transient_array}->[$i] = $val;
	    }
	    elsif ($c2 == 21) {
		#    i get (12 21) val
		# retrieves the value stored in the transient array at the
		# location given by i and pushes the value onto the
		# argument stack. If get is executed prior to put for i
		# during execution of the current charstring, the value
		# returned is undefined.

		my $i = pop @{$self->{v}};
		my $val = $self->{transient_array}->[$i];
		push @{$self->{v}}, $val;
	    }
	    elsif ($c2 == 22) {
		# s1 s2 v1 v2 ifelse (12 22) s1_or_s2
		my $v2 = pop @{$self->{v}};
		my $v1 = pop @{$self->{v}};
		my $s2 = pop @{$self->{v}};
		my $s1 = pop @{$self->{v}};
		if ($v1 <= $v2) {
		    push @{$self->{v}}, $s1;
		} else {
		    push @{$self->{v}}, $s2;
		}
	    }
	    elsif ($c2 == 23) {
		# random (12 23) num2
		# a pseudo random number num2 in the range (0,1], that is,
		# greater than zero and less than or equal to one.
		my $num2 = 1 - rand(1);
		push @{$self->{v}}, $num2;
	    }
	    elsif ($c2 == 24) {
		# num1 num2 mul (12 24) product
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		my $product = $num1 * $num2;
		push @{$self->{v}}, $product;
	    }

	    elsif ($c2 == 26) {
		# num sqrt (12 26) num2
		my $num = pop @{$self->{v}};
		my $num2 = sqrt($num);
		push @{$self->{v}}, $num2;
	    }
	    elsif ($c2 == 27) {
		# any dup (12 27) any any
		my $any = pop @{$self->{v}};
		push @{$self->{v}}, $any, $any;
	    }
	    elsif ($c2 == 28) {
		# num1 num2 exch (12 28) num2 num1
		my $num2 = pop @{$self->{v}};
		my $num1 = pop @{$self->{v}};
		push @{$self->{v}}, $num2, $num1;
	    }
	    elsif ($c2 == 29) {
		# numX ... num0 i index (12 29) numX ... num0 numi

		# retrieves the element i from the top of the argument stack
		# and pushes a copy of that element onto that stack.
		# If i is negative, the top element is copied.
		# If i is greater than X, the operation is undefined.

		my $i = pop @{$self->{v}};
		my $num_i = $self->{v}->[-($i + 1)];
		push @{$self->{v}}, $num_i;
	    }
	    elsif ($c2 == 30) {
		# num(N–1) ... num0 N J roll (12 30) num((J–1) mod N) ... num0
		# num(N–1) ... num(J mod N)

		# performs a circular shift of the elements num(N–1) ... num0
		# on the argument stack by the amount J.
		# Positive J indicates upward motion of the stack;
		# negative J indicates downward motion.
		# The value N must be a non-negative integer,
		# otherwise the operation is undefined.

		my $J = pop @{$self->{v}};
		my $N = pop @{$self->{v}};
		if ($J) {
		    my @tmp = splice @{$self->{v}}, 0, scalar @{$self->{v}} - $N;
		    if ($J > 0) {
			my @num = splice @{$self->{v}}, -$J;
			unshift @{$self->{v}}, @num;
		    } else {
			my @num = splice @{$self->{v}}, 0, -$J;
			push @{$self->{v}}, @num;
		    }
		    unshift @{$self->{v}}, @tmp;
		}
	    }

=begin comment

	    elsif ($c2 == 34) {
		# |- dx1 dx2 dy2 dx3 dx4 dx5 dx6 hflex (12 34) |-
		$self->{v} = []; # clear
	    }
	    elsif ($c2 == 35) {
		# |- dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 dx6 dy6 fd flex (12 35) |-
		$self->{v} = []; # clear
	    }
	    elsif ($c2 == 36) {
		# |- dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6 hflex1 (12 36) |-
		$self->{v} = []; # clear
	    }
	    elsif ($c2 == 37) {
		# |- dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6 flex1 (12 37) |-
		$self->{v} = []; # clear
	    }

=end comment

=cut

	    else {
		confess "plot: unknown_$c,$c2 in class $f->{class}, id $f->{id}";
	    }
	}

	elsif ($c == 14) {
	    # – endchar (14) |–
	    $pen and $pen->closepath;
	    if ($self->can('advance')) {
		$self->{w} = pop @{$self->{v}} unless defined $self->{w};
		my $advance = $self->PrivateDICT->{defaultWidthX};
		if (defined $self->{w}) {
		    $advance = $self->PrivateDICT->{nominalWidthX};
		    $advance += $self->{w};
		}
		$self->advance($advance);
		$self->{v} = []; # clear
		#last;
	    }
	}

	elsif ($c == 18) {
	    # |- y dy {dya dyb}* hstemhm (18) |-
	    #&$hstem unless @{$self->{hs}};
	    unless (@{$self->{hs}}) {
		#my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
		my $r = scalar @{$self->{v}} % 2;
		my $q = int scalar @{$self->{v}} / 2;
		push @{$self->{hs}}, splice @{$self->{v}}, -($q * 2);
		$self->{w} = pop @{$self->{v}} unless defined $self->{w} && $r;
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 19) {
	    # |- hintmask (19 + mask) |-
	    #&$vstem unless @{$self->{vs}};
	    unless (@{$self->{vs}}) {
		#my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
		my $r = scalar @{$self->{v}} % 2;
		my $q = int scalar @{$self->{v}} / 2;
		push @{$self->{vs}}, splice @{$self->{v}}, -($q * 2);
		$self->{w} = pop @{$self->{v}} unless defined $self->{w} && $r;
	    }
	    #&$getmask;
	    my $n = @{$self->{hs}} + @{$self->{vs}};
	    my $s = int(($n + 1) / 2);
	    my $m = int(($s + 7) / 8);
	    my $mask = 0;
	    if ($m >= 1) {
		for (1 .. $m) {
		    $mask <<= 8;
		    my $c = shift @$code;
		    $mask |= $c;
		}
	    }
	    #sprintf "%0*b", 8*$m, $mask;
	    $self->{v} = []; # clear
	}
	elsif ($c == 20) {
	    # |- cntrmask (20 + mask) |-
	    #&$vstem unless @{$self->{vs}};
	    unless (@{$self->{vs}}) {
		#my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
		my $r = scalar @{$self->{v}} % 2;
		my $q = int scalar @{$self->{v}} / 2;
		push @{$self->{vs}}, splice @{$self->{v}}, -($q * 2);
		$self->{w} = pop @{$self->{v}} unless defined $self->{w} && $r;
	    }
	    #&$getmask;
	    my $n = @{$self->{hs}} + @{$self->{vs}};
	    my $s = int(($n + 1) / 2);
	    my $m = int(($s + 7) / 8);
	    my $mask = 0;
	    if ($m >= 1) {
		for (1 .. $m) {
		    $mask <<= 8;
		    my $c = shift @$code;
		    $mask |= $c;
		}
	    }
	    #sprintf "%0*b", 8*$m, $mask;
	    $self->{v} = []; # clear
	}
	elsif ($c == 21) {
	    # |- dx1 dy1 rmoveto (21) |-
	    my ($dx1, $dy1) = splice @{$self->{v}}, 0, 2;
	    $pen and $pen->moveto($dx1, $dy1);
	    $self->{v} = []; # clear
	}
	elsif ($c == 22) {
	    # |- dx1 hmoveto (22) |-
	    my ($dx1) = shift @{$self->{v}};
	    $pen and $pen->moveto($dx1, 0);
	    $self->{v} = []; # clear
	}
	elsif ($c == 23) {
	    # |- x dx {dxa dxb}* vstemhm (23) |-
	    #&$vstem unless @{$self->{vs}};
	    unless (@{$self->{vs}}) {
		#my ($q, $r) = idiv(scalar @{$self->{v}}, 2);
		my $r = scalar @{$self->{v}} % 2;
		my $q = int scalar @{$self->{v}} / 2;
		push @{$self->{vs}}, splice @{$self->{v}}, -($q * 2);
		$self->{w} = pop @{$self->{v}} unless defined $self->{w} && $r;
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 24) {
	    # |- {dxa dya dxb dyb dxc dyc}+ dxd dyd rcurveline (24) |-
	    while (@{$self->{v}} >= 6) {
		my ($dxa, $dya, $dxb, $dyb, $dxc, $dyc) = splice @{$self->{v}}, 0, 6;
		$pen and $pen->curveto($dxa, $dya, $dxb, $dyb, $dxc, $dyc);
	    }
	    my ($dxa, $dya) = splice @{$self->{v}}, 0, 2;
	    $pen and $pen->lineto($dxa, $dya);
	    $self->{v} = []; # clear
	}
	elsif ($c == 25) {
	    # |- {dxa dya}+ dxb dyb dxc dyc dxd dyd rlinecurve (25) |-
	    while (@{$self->{v}} >= 2 + 6) {
		my ($dxa, $dya) = splice @{$self->{v}}, 0, 2;
		$pen and $pen->lineto($dxa, $dya);
	    }
	    my ($dxb, $dyb, $dxc, $dyc, $dxd, $dyd) = splice @{$self->{v}}, 0, 6;
	    $pen and $pen->curveto($dxb, $dyb, $dxc, $dyc, $dxd, $dyd);
	    $self->{v} = []; # clear
	}
	elsif ($c == 26) {
	    # |- dx1? {dya dxb dyb dyc}+ vvcurveto (26) |-
	    #my ($q, $r) = idiv(scalar @{$self->{v}}, 4);
	    my $r = scalar @{$self->{v}} % 4;
	    #my $q = int scalar @{$self->{v}} / 4;
	    my $dx1 = shift @{$self->{v}} if $r == 1;
	    while (@{$self->{v}} >= 4) {
		my ($dya, $dxb, $dyb, $dyc) = splice @{$self->{v}}, 0, 4;
		$pen and $pen->curveto($dx1 // 0, $dya, $dxb, $dyb, 0, $dyc);
		$dx1 = undef;
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 27) {
	    # |- dy1? {dxa dxb dyb dxc}+ hhcurveto (27) |-
	    #my ($q, $r) = idiv(scalar @{$self->{v}}, 4);
	    my $r = scalar @{$self->{v}} % 4;
	    #my $q = int scalar @{$self->{v}} / 4;
	    my $dy1 = shift @{$self->{v}} if $r == 1;
	    while (@{$self->{v}} >= 4) {
		my ($dxa, $dxb, $dyb, $dxc) = splice @{$self->{v}}, 0, 4;
		$pen and $pen->curveto($dxa, $dy1 // 0, $dxb, $dyb, $dxc, 0);
		$dy1 = undef;
	    }
	    $self->{v} = []; # clear
	}
	# 28: following 2 bytes interpreted as a 16-bit two's complement number
	elsif ($c == 29) {
	    # globalsubr# callgsubr (29) –
	    my $subr = pop @{$self->{v}};
	    my $class = 'GlobalSubr_INDEX';
	    my $cs = $self->$class;
	    my $index = $subr + $cs->bias;
	    my $code = $cs->data($index);
	    $self->_plot({ %$f, class => $class, id => $index }, $code, $pen);
	}
	elsif ($c == 30) {
	    # |- dy1 dx2 dy2 dx3 {dxa dxb dyb dyc dyd dxe dye dxf}* dyf? vhcurveto (30) |-
	    # |- {dya dxb dyb dxc dxd dxe dye dyf}+ dxf? vhcurveto (30) |-
	    #my ($q, $r) = idiv(scalar @{$self->{v}}, 8);
	    my $r = scalar @{$self->{v}} % 8;
	    #my $q = int scalar @{$self->{v}} / 8;
	    if ($r == 4 || $r == 5) {
		my ($dy1, $dx2, $dy2, $dx3) = splice @{$self->{v}}, 0, 4;
		my $dyf = shift @{$self->{v}} if @{$self->{v}} == 1;
		$pen and $pen->curveto(0, $dy1, $dx2, $dy2, $dx3, $dyf // 0);
		while (@{$self->{v}} >= 8) {
		    my ($dxa, $dxb, $dyb, $dyc, $dyd, $dxe, $dye, $dxf) = splice @{$self->{v}}, 0, 8;
		    my $dyf = shift @{$self->{v}} if @{$self->{v}} == 1;
		    $pen and $pen->curveto($dxa, 0, $dxb, $dyb, 0, $dyc);
		    $pen and $pen->curveto(0, $dyd, $dxe, $dye, $dxf, $dyf // 0);
		}
	    } elsif ($r == 0 || $r == 1) {
		while (@{$self->{v}} >= 8) {
		    my ($dya, $dxb, $dyb, $dxc, $dxd, $dxe, $dye, $dyf) = splice @{$self->{v}}, 0, 8;
		    my $dxf = shift @{$self->{v}} if @{$self->{v}} == 1;
		    $pen and $pen->curveto(0, $dya, $dxb, $dyb, $dxc, 0);
		    $pen and $pen->curveto($dxd, 0, $dxe, $dye, $dxf // 0, $dyf);
		}
	    }
	    $self->{v} = []; # clear
	}
	elsif ($c == 31) {
	    # |- dx1 dx2 dy2 dy3 {dya dxb dyb dxc dxd dxe dye dyf}* dxf? hvcurveto (31) |-
	    # |- {dxa dxb dyb dyc dyd dxe dye dxf}+ dyf? hvcurveto (31) |-
	    #my ($q, $r) = idiv(scalar @{$self->{v}}, 8);
	    my $r = scalar @{$self->{v}} % 8;
	    #my $q = int scalar @{$self->{v}} / 8;
	    if ($r == 4 || $r == 5) {
		my ($dx1, $dx2, $dy2, $dy3) = splice @{$self->{v}}, 0, 4;
		my $dxf = shift @{$self->{v}} if @{$self->{v}} == 1;
		$pen and $pen->curveto($dx1, 0, $dx2, $dy2, $dxf // 0, $dy3);
		while (@{$self->{v}} >= 8) {
		    my ($dya, $dxb, $dyb, $dxc, $dxd, $dxe, $dye, $dyf) = splice @{$self->{v}}, 0, 8;
		    my $dxf = shift @{$self->{v}} if @{$self->{v}} == 1;
		    $pen and $pen->curveto(0, $dya, $dxb, $dyb, $dxc, 0);
		    $pen and $pen->curveto($dxd, 0, $dxe, $dye, $dxf // 0, $dyf);
		}
	    } elsif ($r == 0 || $r == 1) {
		while (@{$self->{v}} >= 8) {
		    my ($dxa, $dxb, $dyb, $dyc, $dyd, $dxe, $dye, $dxf) = splice @{$self->{v}}, 0, 8;
		    my $dyf = shift @{$self->{v}} if @{$self->{v}} == 1;
		    $pen and $pen->curveto($dxa, 0, $dxb, $dyb, 0, $dyc);
		    $pen and $pen->curveto(0, $dyd, $dxe, $dye, $dxf, $dyf // 0);
		}
	    }
	    $self->{v} = []; # clear
	}
	else {
	    confess "plot: unknown_$c in class $f->{class}, id $f->{id}";
	}
    }
}


sub install {
    my ($self) = @_;

    no strict 'refs';
    *{"Font::TTF::CFF_::plot"}  = \&plot_  unless Font::TTF::CFF_->can('plot');
    *{"Font::TTF::CFF_::_plot"} = \&_plot_ unless Font::TTF::CFF_->can('_plot');

    $self;
}


1;

__END__
