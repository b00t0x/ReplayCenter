# Third-party sources

This directory contains vendored source files used by `ReplayCenterStreamFilter`.

## tsreadex

- Upstream: https://github.com/xtne6f/tsreadex
- Base commit: `a82528ccb698fcd07b4da1bb2243e63d685c34a7`
- Vendored path: `tsreadex/`
- Line endings: normalized to LF in this repository.
- License: `tsreadex/License.txt`

Vendored files:

- `aac.cpp`
- `aac.hpp`
- `huffman.cpp`
- `huffman.hpp`
- `util.cpp`
- `util.hpp`
- `License.txt`

Applied local patches:

1. `patches/tsreadex-replaycenter.patch`
   - Defers `isDualMono = true` in `Aac::TransmuxDualMono` until the current
     ADTS frame has been fully verified as dual mono.
   - Keeps `isDualMono = false` on unsupported or invalid frames.
   - This avoids transient dual-mono detection while ReplayCenter is observing
     stream audio state.

Update procedure:

1. Fetch or clone upstream tsreadex at the target commit.
2. Copy the vendored files listed above into `tsreadex/`.
3. Normalize copied files to LF line endings.
4. Apply local patches from this directory:

   ```sh
   patch -p0 < patches/tsreadex-replaycenter.patch
   ```

5. Update the base commit in this file.
6. Build `ReplayCenterStreamFilter` and verify dual mono / stereo-single audio
   state detection with real streams.
