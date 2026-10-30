# Upload this repo to GitHub and trigger the XNU build (Windows PowerShell)

This host can reach `api.github.com` but **not** `github.com` (git push/HTTPS is
blocked here). The script below uses only the GitHub REST API, so no git and no
`github.com` access is needed on this PC — only a token.

## 1. Create the token (2 minutes)

Open GitHub in a browser **on a device that can reach github.com** (phone
hotspot / VPN is fine):

- Settings → Developer settings → Personal access tokens → **Tokens (classic)**
- Generate new token, expiry 7 days, scopes: **repo** and **workflow**
- Copy the `ghp_...` string.

The token can create the repository, upload the files and start the macOS
runner. Revoke it when the build is done.

## 2. Run

```powershell
powershell -ExecutionPolicy Bypass -File G:\ios16sagit\ios16_on_sagit_mi6\tools\upload-to-github.ps1
```

It asks for your GitHub username and the token (hidden), creates
`ios16_on_sagit_mi6`, uploads every tracked source file (no `.git`, no `out/`),
starts the **xnu** workflow with `machine_config=SWEET`,
`kernel_config=DEVELOPMENT`, waits for it and downloads the artifact to
`xnu/out/kernel.development.sweet`.

If the runner image `macos-14` has already been retired (GitHub removes it
around 2026-11-02), the job stays queued/fails immediately; tell me and we use
the macOS VM instead.

## 3. After it finishes

```powershell
cd G:\ios16sagit\ios16_on_sagit_mi6
tools\build-sagit-boot.sh xnu/out/kernel.development.sweet 6   # run inside Linux
```

or tell me and I will package + verify `out/shim-sagit-xnu.img` for you.

## Manual alternative

If you prefer not to use the script: create an empty repo, then in a browser
upload the folder contents (GitHub web upload accepts a dragged folder, but
split into batches under 100 files), commit to `main`, open **Actions → xnu →
Run workflow** with `machine_config=SWEET`, `kernel_config=DEVELOPMENT`, then
download the `xnu-kernel` artifact.
