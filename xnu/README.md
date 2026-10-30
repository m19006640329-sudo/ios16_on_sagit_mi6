# XNU for sagit (Xiaomi Mi 6)

Built on GitHub's macOS arm64 runners by `.github/workflows/xnu.yml`, using
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) (MIT)
at a pinned commit.

- `MACOS_VERSION=13.5` -> xnu-8796 (iOS 16.6/16.7 generation).
- `patches/*.patch` are copied into the build script's patch dir and applied
  in numeric order. `0001`–`0081` are the unmodified sweet base patches;
  `0082-sagit-mi6-xnu-port.patch` is the complete sagit board port (ADT board
  gates, 1080x1920 display scaling, Synaptics RMI4 touch over GPIO87/88,
  RELEASE launchd entitlement gate). It replaces the twelve Polaris patches
  from the upstream MIX 2S branch.
- `machine_config=SWEET` is intentional: sagit reuses the SWEET machine config
  and differs only through its ADT, boot arguments and patch 0082.
- Output artifact: `kernel.<config>.sweet` (Mach-O, **not** an Android boot
  image; package it with `tools/mkpayload.py` + `PLATFORM=sagit shim/build.sh`).

Fetch a build from your own fork:

```sh
gh run download -R <you>/<repo> -n xnu-kernel -D xnu/out
```

Verified offline in this repository: the full series 0001–0082 applies cleanly
to xnu-8796.141.3 with `git apply`. It has **not** been compiled here (no Apple
toolchain in the development VM).
