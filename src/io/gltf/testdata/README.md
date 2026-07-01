# glTF loader test fixtures

These model files are copied from the [tinygltf](https://github.com/syoyo/tinygltf)
test suite (`tests/` and `models/`), which in turn draws several assets from the
[KhronosGroup glTF-Sample-Models](https://github.com/KhronosGroup/glTF-Sample-Models).
They are used only by `src/io/gltf/tests.zig` to exercise the loader against
real-world `.gltf`/`.glb` files. See those upstream projects for licensing.

Curated subset:

- `box01.glb`, `issue-492.glb`, `zero-sized-bin-chunk-issue-440.glb`,
  `singleBlendshapeCube_sparse.glb` — binary GLB variants.
- `extensions-issue97.gltf` — ASCII glTF with a base64 data-URI buffer
  (self-contained).
- `invalid-buffer-view-index.gltf`, `invalid-primitive-indices.gltf`,
  `integer-out-of-bounds.gltf` — bounds-checking cases.
- `Cube/` — ASCII glTF with an external `.bin` and two external PNG images.
- `CubeImageUriSpaces/` — image URIs containing spaces.
- `BoundsChecking/` — `invalid-buffer-index.gltf` plus its `simpleTriangle.bin`.
