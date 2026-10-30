# Working on ios16_on_sagit_mi6

- Read `NOTES.md` before starting: goal, hardware facts, what is verified,
  current blocker and next concrete action.
- This repository is the **sagit (Xiaomi Mi 6, MSM8998)** port of the Polaris
  (Mi MIX 2S, SDM845) XNU/iOS-16 bring-up. Do not reintroduce polaris
  addresses, `qcom,sdm845`/`xiaomi,polaris` board gates or A630 GPU code.
- XNU uses the upstream `SWEET` machine config; sagit board differences live in
  `tools/mkadt.py --sagit`, `shim` (`SAGIT`), `dtb/sagit/` and the single XNU
  patch `xnu/patches/0082-sagit-mi6-xnu-port.patch`.
- The XNU kernel must be built on macOS / GitHub Actions
  (`.github/workflows/xnu.yml`, `machine_config=SWEET`). This repository has no
  Apple toolchain; do not claim a kernel build or a boot without a log.
- Device bring-up only via temporary `fastboot boot` unless the user explicitly
  confirms a partition write. Keep the original `boot`, `persist`, `modemst*`
  and `userdata` backups; never flash bootloader/modem/persist.
- Update `NOTES.md` with commits, hashes, exact build/boot/touch results and
  unfinished work. Distinguish measured facts from hypotheses.
- Keep Apple images, Qualcomm firmware, stock DTB/device dumps and serial
  numbers out of git. `dtb/sagit/*.dtb` and `artifacts/sagit/*` are generated
  from public sources and may be committed.
