use strict;
use warnings;
use Test::More;
use Config;
use Data::Histogram::Shared;

plan skip_all => 'fork required' unless $Config{d_fork};

# Argument magic that explicitly calls $obj->DESTROY frees the C handle
# mid-method.  record() reads its optional count with SvUV(ST(2)) and
# record_many() reads each element with SvIV(*el) AFTER EXTRACT pinned the
# handle, so an overloaded '0+' on those arguments runs Perl code between
# EXTRACT and the first use of the handle.  Without the REEXTRACT guard the
# method then dereferences the freed handle and segfaults; with it the method
# must croak cleanly ("destroyed during the call").  Each child exits 0 when
# the method croaked, 7 when it ran on through freed memory, and dies by
# signal if it crashed -- so this test fails if the REEXTRACT calls are
# removed.
#
# Note: record()'s mandatory value argument is converted in the INPUT section
# before EXTRACT runs, so magic on it is caught by EXTRACT itself; only the
# optional count (ST(2)) exercises the REEXTRACT path.

{
    package Evil;
    use overload
        '0+' => sub { $_[0][0]->DESTROY; 1 },
        '""' => sub { $_[0][0]->DESTROY; 'k' },
        fallback => 1;
}

my %call = (
    record      => sub { my ($o, $e) = @_; $o->record(1, $e) },
    record_many => sub { my ($o, $e) = @_; $o->record_many([1, $e]) },
);

for my $method (sort keys %call) {
    my $pid = fork();
    unless ($pid) {
        my $obj  = Data::Histogram::Shared->new(undef, 1, 1_000_000, 3);
        my $evil = bless [$obj], 'Evil';
        my $ok = eval { $call{$method}->($obj, $evil); 1 };
        exit($ok ? 7 : 0);   # 0 = croaked (correct), 7 = ran on through freed memory
    }
    waitpid($pid, 0);
    my $st = $?;
    ok !($st & 127), "$method: no crash when argument magic destroys the handle"
        or diag sprintf('died with signal %d', $st & 127);
    is $st >> 8, 0, "$method: croaks instead of using the freed handle";
}

done_testing;
