# Build Context APPX on Windows (PowerShell-only)

This guide builds `Context.appx` on a Windows machine using one PowerShell command.

## What this does

The bootstrap script will:

1. Find Flutter on `PATH` OR reuse/download a portable Flutter SDK to a shared `appx\\deps\\flutter` folder (default)
2. Run `flutter doctor -v`
3. Install Visual Studio Build Tools (Desktop C++) if missing (UAC prompt)
4. Build the Windows release binary
5. Create/trust a local dev signing certificate (LocalMachine\\Root + LocalMachine\\TrustedPeople; UAC prompt)
6. Package and sign `Context.appx`

Output:

- `Context.appx` (single-file install package; created in project root)
- `Context-portable\\` (optional portable folder; run `context.exe` inside)

## Step-by-step

### 1) Open PowerShell

- Recommended: Windows PowerShell 5.1 (`powershell.exe`)
- You can run as a normal user; the script will request admin for Build Tools and for trusting the signing certificate (needed to install the APPX).

### 2) Go to the project folder

```powershell
cd C:\path\to\Context
```

### 3) Build (choose one)

**Option A (in-place, keeps everything in this project folder):**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows_appx.ps1
```

**Option A2 (portable folder only, no APPX packaging):**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows_appx.ps1 -PortableOnly
```

**Option B (work-dir copy, best if your repo folder is a junction/WSL/UNC path):**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_build_appx_local.ps1 -WorkDir "$env:TEMP\context-win" -CleanWorkDir
```

### 4) Find the result

```powershell
dir .\Context.appx
dir .\Context-portable
```

## Common fixes

### `git : The term 'git' is not recognized...` / `Unable to determine engine version`

Install **Git for Windows** and make sure `git.exe` is on `PATH` (then reopen PowerShell).

```powershell
winget install --id Git.Git -e --source winget
git --version
```

### `0x800B0109` / `0x800B010A` (publisher certificate could not be verified)

This happens if you try to install an APPX that is signed with a certificate your machine does not trust.

If it happens, run this once from an **elevated** PowerShell (Run as Administrator):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\trust_appx_cert.ps1 -AppxPath .\Context.appx
```

If you copy `Context.appx` to a different machine, you must also trust the signing certificate on that machine (or sign with a real code-signing certificate).
