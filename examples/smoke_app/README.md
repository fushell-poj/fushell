# Fushell smoke application

The main window, settings windows, and optional layer-shell bar share one engine.
`FushellWindowViews` renders them with stable per-view keys and caller-selected
content. `FushellWindowController` owns creation and waits for view readiness
before publishing a window. A readiness failure closes the new native window.

Unmounting the root disposes its owner: pending readiness is cancelled and ready
windows are closed. A native create cannot be cancelled, so asynchronous disposal
waits for its reply and closes the returned ID even after unmount. Failed closes
retain ownership and can be retried; disposal errors are reported to Flutter.

Closing all native windows intentionally leaves the process running headless.
Only the explicit exit action calls `FushellProcess.exit`. Parent/transient window
relationships do not cascade native close; ownership cleanup is explicit.
