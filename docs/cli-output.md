# Creation and build output

`fushell create bar` only advertises the published `bar` directory and
`fushell run`. Flutter's scaffold instructions and formatter output refer to a
private `.fushell-create-*` workspace, so those tools are captured and their
successful output is not forwarded. On failure both output streams are shown
as diagnostics. The final project `pub get` still displays its own output; it
runs in the published directory, and failure does not delete the project.

Builds still assemble into a sibling `.debug.fushell-stage-*` (or corresponding
profile/release) directory before publication. `bundle entry:` is emitted only
after publication succeeds, and contains the absolute final executable path.
No entry or ready message is emitted for a compiler, download, hash, or
publication failure. Failure leaves the previous recognized bundle unchanged.

Engine download and Dart compilation remain concurrent. curl keeps its real
progress bar; command traces such as `$ mkdir ...` are no longer printed.
Compiler stdout/stderr are captured while the meter owns the terminal and
replayed after the transfer has completed or been cancelled/reaped. A build
phase message is printed before starting the transfer. Warnings and errors are
not silently discarded: each stream retains its final 1 MiB, with an explicit
notice when earlier output was omitted. Even larger output is drained without
aborting the tool. The display-only buffering does not change compiler flags,
Engine selection, hash validation, destination rules or the publication policy.

`tests/output_smoke.py` checks these contracts using the compiled CLI and fake
SDK/download executables. It covers all three bundle modes, custom paths,
concurrent progress, failure diagnostics, no-overwrite creation, preserved
bundles, cancelled curl cleanup and publication conflicts. The ordinary CLI
smoke suite runs it. The real Flutter doctor integration also checks that
successful creation exposes no private workspace instructions. These tests do
not imply actual Flutter application compilation or GPU rendering coverage.

## Exit, output, and cancellation are separate events

A captured command may run for as long as its build needs. Capture checks both
stream errors immediately after reader initialization and after each read;
an allocation/read failure cannot be hidden behind an unrelated open pipe.
Direct-child exit is observed with Linux `waitid(WNOWAIT | WNOHANG)` without
reaping or closing the pipes. Once exit is observed, inherited pipes get up to
250 ms to drain. If a background descendant keeps them open, capture cancels
pending reads, closes its own handles, reports the omitted output, and returns
the direct child's status instead of waiting forever for EOF.

Pending reads are cancelled before wait closes pipe handles. Normal reaping is
uncancellable only after exit has been observed. On cancellation or capture
failure, cleanup sends TERM to the owned direct child, allows a 250 ms grace
period, then sends KILL if necessary and reaps it. No PID or closed descriptor
is restored after a failed Zig 0.16 `Child.wait`.

Tools keep the inherited terminal process group so terminal Ctrl+C continues
to reach them; the wrapper never sends group-wide signals to that shared group.
It owns/reaps the direct child, not arbitrary grandchildren or detached daemons.
After the drain deadline it closes its read handles rather than claiming to
kill background descendants it does not own. Kernel-uninterruptible processes
can still delay reaping even after KILL; the grace period is not an absolute
OS-level exit guarantee. These limits do not cap normal Flutter compilation.

Replay retains command boundaries: each command's stdout and stderr are shown
before the next command, and missing trailing newlines cannot join two steps.
Within one command the separate streams do not provide a reliable total order;
each stream's byte order is preserved. Step offsets remain valid when old
output is trimmed. Unit regressions cover capture allocation failure, inherited
pipe writers, open/closed pipes during cancellation, ignored TERM, exit status,
longer-running normal commands, and command-boundary replay.
