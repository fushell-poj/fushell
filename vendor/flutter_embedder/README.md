# Flutter embedder header

`flutter_embedder.h` is vendored **without modification** from Flutter revision
`42d3d75a56efe1a2e9902f52dc8006099c45d937`. Only this architecture-independent C
header is used at build time; no Flutter Engine library is linked or bundled by
this dependency. The runtime Engine selection is unchanged.

## Provenance and verification

- Upstream source: <https://github.com/flutter/flutter/blob/42d3d75a56efe1a2e9902f52dc8006099c45d937/engine/src/flutter/shell/platform/embedder/embedder.h>
- Original archive: <https://storage.googleapis.com/flutter_infra_release/flutter/42d3d75a56efe1a2e9902f52dc8006099c45d937/linux-x64/linux-x64-embedder.zip>
- Former Zig archive package hash: `N-V-__8AAL54uQXWug4lO7AF95z4QCj_ebYcohluWqWYGmfb`
- Header size: **166577 bytes**
- Header SHA-256: `4d004e246a5c5aea606248fa346920ffae71fc5c60bbff14d932b661c77ba729`

The existing cached archive header was compared byte-for-byte against the raw
upstream source at that exact revision, then the vendored copy was compared
byte-for-byte against the cached header. All three match. No declarations, ABI
layouts, or version constants were changed. The old archive license note links
to flutter/engine URLs that no longer resolve for this revision; the source is
now in the flutter/flutter monorepo at the path above.

## License

The header copyright notice refers to the source tree BSD-style license.
`LICENSE` is the exact BSD-3-Clause license from the same revision:
<https://github.com/flutter/flutter/blob/42d3d75a56efe1a2e9902f52dc8006099c45d937/engine/src/flutter/LICENSE>.

License SHA-256: `89519eca6f7b9529b35bdddd623a58c3af06a88c458dbd6531ddb4675acf75a9`.
Retain this license and the header copyright notice when redistributing.

## Updating

Choose an explicit upstream revision, verify its header and source license,
replace both exact files, and update the provenance and hashes here. Review ABI
compatibility separately; do not trim or regenerate this header. Verify locally:

```sh
sha256sum vendor/flutter_embedder/flutter_embedder.h vendor/flutter_embedder/LICENSE
```
