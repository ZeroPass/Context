# Context APPX kit

This checkout vendors the four PowerShell scripts required for its Windows
APPX packaging under `appx/scripts/`:

- `windows_build_appx_local.ps1` — copy-builds from a WSL/UNC or junction path.
- `bootstrap_windows_appx.ps1` — prepares Flutter and the Windows toolchain.
- `build_appx.ps1` — builds, packages, and signs the APPX.
- `trust_appx_cert.ps1` — trusts a generated signing certificate.

The wrappers in `scripts/` resolve these files from this repository only. The
kit is self-contained as source, but external Windows build tools and the
Flutter/Rust dependency caches remain outside the repository. See
`BUILD_WINDOWS_APPX_POWERSHELL.md` for prerequisites and cache overrides.
