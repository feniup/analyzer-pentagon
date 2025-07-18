# Assumptions

Goblint makes the following (implicit) assumptions about the systems and programs it analyzes.

_NB! This list is likely incomplete._

1. `PTHREAD_MUTEX_DEFAULT` is a non-recursive mutex type.

    Although the [POSIX Programmer's Manual](https://linux.die.net/man/3/pthread_mutexattr_settype) states that

    > An implementation may map this mutex to one of the other mutex types.

    including `PTHREAD_MUTEX_RECURSIVE`, on Linux and OSX it seems to be mapped to `PTHREAD_MUTEX_NORMAL`.
    Goblint assumes this to be the case.

    This affects the `maylocks` analysis.

    See [PR #1414](https://github.com/goblint/analyzer/pull/1414).

2.  Pointer arithmetic does not overflow.

    [C11's N1570][n1570] at 6.5.6.8 states that

    > When an expression that has integer type is added to or subtracted from a pointer, the result has the type of the pointer operand.
    > [...]
    > the evaluation shall not produce an overflow; otherwise, the behavior is undefined.

    after a long list of defined behaviors.

    Goblint does not report overflow and out-of-bounds pointer arithmetic (when the pointer _is not dereferenced_).
    This affects the overflow analysis (SV-COMP no-overflow property) in the `base` analysis.

    This _does not_ affect the `memOutOfBounds` analysis (SV-COMP valid-memsafety property), which is for undefined behavior from _dereferencing_ such out-of-bounds pointers.

    See [PR #1511](https://github.com/goblint/analyzer/pull/1511).

3.  Memory allocated with `malloc` is initialized before reading.

    [C11's N1570][n1570] at J.2 states that

    > The behavior is undefined in the following circumstances:
    >
    > - [...]
    > - The value of the object allocated by the `malloc` function is used (7.22.3.4).

    after a long list of undefined behaviors.

    Goblint does not report reading from uninitialized memory allocated by `malloc`.

    This affects the `base` analysis.

    See [issue #1770](https://github.com/goblint/analyzer/issues/1770).

4.  Array index reads are in bounds.

    [C11's N1570][n1570] at J.2 states that

    > The behavior is undefined in the following circumstances:
    >
    > - [...]
    > - An array subscript is out of range, even if an object is apparently accessible with the given subscript (as in the lvalue expression `a[1][7]` given the declaration `int a[4][5]`) (6.5.6).

    after a long list of undefined behaviors.

    Goblint does not by default report reading from out of bounds array indices.
    Goblint reports out of bounds array index accesses when the `ana.arrayoob` option is enabled.

    This affects the `base` analysis.

    See [issue #1702](https://github.com/goblint/analyzer/issues/1702).


[n1570]: https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf
