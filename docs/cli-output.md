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
