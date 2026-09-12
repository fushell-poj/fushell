# Vendored Wayland protocol snapshots

These are complete, unmodified official XML snapshots, including all interfaces, descriptions, enumerations, and copyright/license notices. Generation selects seven interfaces but never reduces these source files. No network access is used when generating or checking bindings.

| File | Pinned source | SHA-256 |
| --- | --- | --- |
| `wayland.xml` | [Wayland 1.24.0](https://gitlab.freedesktop.org/wayland/wayland/-/raw/1.24.0/protocol/wayland.xml) | `60abb5864546288a660f3d8af0c838fc87c85bb386582da23e52cb8476e9adbf` |
| `ext-workspace-v1.xml` | [wayland-protocols 1.49](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/raw/1.49/staging/ext-workspace/ext-workspace-v1.xml) | `9b449d9d5d40f6032eba9813d18093b84f249a2cf38d6755dec7bca7eb96b0f3` |

The extension snapshot was copied byte-for-byte from `/nix/store/2nlq43n0gc4s8cbjjxpnfg97kgmk8blh-wayland-protocols-1.49/share/wayland-protocols/staging/ext-workspace/ext-workspace-v1.xml`. The core snapshot was downloaded directly from the pinned official URL above. Upstream copyright notices are also copied into generated Dart comments.

To update, deliberately replace the full snapshots from a pinned official release, update this provenance and hashes, regenerate, and review changes to the schema and bindings.
