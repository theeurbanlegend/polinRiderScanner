# PolinRider Malware Scanner

A standalone scanner to check your local projects for signs of **PolinRider** — a supply-chain malware family delivered through malicious npm packages.

---

## What is PolinRider?

PolinRider is a JavaScript-based malware spread through fake npm packages designed to look like legitimate libraries. Known delivery packages include `tailwind-mainanimation` and `tailwind-autoanimation`, which impersonate TailwindCSS tools.

When you run `npm install`, a post-install script silently injects an obfuscated JavaScript payload into your project's config files — most commonly `postcss.config.mjs`, but also `*.config.ts`, `*.config.js`, `app.js`, and others. Because these files run automatically on every build, the malware executes every time you run `npm run dev` or `npm run build` — with no visible indication.

The payload connects to blockchain-based command-and-control (C2) servers on the TRON and Aptos networks to download further instructions and exfiltrate secrets such as API keys and environment variables. It also drops a `temp_auto_push.bat` script that amends and force-pushes your git commits to GitHub, spreading the infected files to anyone who clones your repositories.

The infection is designed to be silent. Files look nearly normal — the payload is hidden after hundreds of blank lines at the end of a config file.

For a full technical breakdown of the campaign — including malware analysis, C2 infrastructure, obfuscation layers, IOCs, and the full list of compromised repositories — see the [OpenSourceMalware PolinRider report](https://github.com/OpenSourceMalware/PolinRider).

---

## What the scanner checks

The scanner runs four phases across the directory you point it at:

**Phase 1 — Signature scan:** Searches all config files for signatures from both active PolinRider obfuscator variants. Each match is labelled `v1-primary` / `v1-secondary` (original March 2026 variant) or `v2-primary` / `v2-secondary` (rotated April 2026 `Cot%3t=shtP` variant). A file can carry both if the machine was re-infected after a partial cleanup.

**Phase 2 — Git artifact check:** Searches every git repository in the target directory for:

- `temp_auto_push.bat` — the propagation script
- `config.bat` — a hidden orchestrator script
- Injected entries in `.gitignore` (used to hide the above)
- Amended commits in `git reflog` (consistent with force-push activity)

**Phase 3 — `.vscode/tasks.json` check:** Searches for the TasksJacker delivery vector, which merged operationally with PolinRider in April 2026. Flags any `tasks.json` that references a known Vercel-hosted C2 subdomain, the StakingGame fake-interview template UUID, or a task configured to auto-execute `curl`/`wget` when the folder is opened.

**Phase 4 — `package.json` check:** Searches all `package.json` files for the 7 known malicious npm packages published by the threat actor, including those used in the ShoeVista fake job-interview template.

---

## Running on Windows (PowerShell)

### Prerequisites

- **Git** — download from [git-scm.com](https://git-scm.com) if not already installed
- **PowerShell** — built into Windows 10 and 11 (search "PowerShell" in the Start menu)

### Steps

**1. Open PowerShell**

Press `Win + S`, search for **PowerShell**, and open it. You do not need to run it as Administrator.

**2. Clone the scanner repository**

```powershell
git clone https://github.com/theeurbanlegend/polinRiderScanner
cd polinrider-scanner
```

**3. Allow the script to run**

Windows blocks unsigned scripts by default. Run this once to allow locally-cloned scripts:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Type `Y` and press Enter when prompted.

**4. Run the scanner**

Scan your entire projects folder (replace the path with wherever you keep your work):

```powershell
.\polinrider-scanner.ps1 C:\Users\YourName\projects
```

Or scan only the current directory:

```powershell
.\polinrider-scanner.ps1
```

**Optional flags:**

| Flag       | What it does                                                |
| ---------- | ----------------------------------------------------------- |
| `-Verbose` | Shows every file being checked as it runs                   |
| `-JsAll`   | Also scans all `.js` files, not just known config filenames |

Example with flags:

```powershell
.\polinrider-scanner.ps1 -Verbose -JsAll C:\Users\YourName\projects
```

---

## Running on macOS / Linux (bash)

### Prerequisites

- **Git** — usually pre-installed. Confirm by running `git --version` in Terminal. If missing, install it via your package manager (`brew install git` on macOS, `sudo apt install git` on Ubuntu/Debian).
- **Terminal** — pre-installed on all macOS and Linux systems.

### Steps

**1. Open Terminal**

On macOS: press `Cmd + Space`, type **Terminal**, and press Enter.
On Linux: press `Ctrl + Alt + T`, or search for Terminal in your app launcher.

**2. Clone the scanner repository**

```bash
git clone https://github.com/theeurbanlegend/polinRiderScanner
cd polinrider-scanner
```

**3. Make the script executable**

```bash
chmod +x polinrider-scanner.sh
```

This only needs to be done once.

**4. Run the scanner**

Scan your projects folder (replace the path with wherever you keep your work):

```bash
./polinrider-scanner.sh ~/projects
```

On macOS, if most of your work is on the Desktop:

```bash
./polinrider-scanner.sh ~/Desktop
```

Or scan only the current directory:

```bash
./polinrider-scanner.sh
```

**Optional flags:**

| Flag        | What it does                                                |
| ----------- | ----------------------------------------------------------- |
| `--verbose` | Shows every file being checked as it runs                   |
| `--js-all`  | Also scans all `.js` files, not just known config filenames |

Example with flags:

```bash
./polinrider-scanner.sh --verbose --js-all ~/projects
```

---

## Understanding the output

A clean result looks like this:

```
========================================
  PolinRider Malware Scanner v1.2
  https://opensourcemalware.com
========================================

Scanning: /Users/yourname/projects

Checking config files for malware signatures...
Checking 12 git repositories for artifacts...

Checking .vscode/tasks.json files for TasksJacker payloads...
Checking package.json for malicious npm packages...

[CLEAN] 12 repositories scanned clean

========================================
  RESULTS: No infections found
========================================
```

If an infection is found, the scanner prints the exact file and what was detected. The variant label tells you which obfuscator strain is present:

```
[INFECTED] 2 file(s) with malware signatures found
  - /Users/yourname/projects/my-app/postcss.config.mjs: PolinRider payload detected (v1-primary)
  - /Users/yourname/projects/my-app/tailwind.config.js: PolinRider payload detected (v2-primary v2-secondary)

[INFECTED] /Users/yourname/projects/my-app
  - temp_auto_push.bat: Propagation script found
  - .gitignore: config.bat entry injected

[INFECTED] 1 tasks.json file(s) with TasksJacker payload found
  - /Users/yourname/projects/my-app/.vscode/tasks.json: Malicious tasks.json (C2:default-configuration.vercel.app)

[INFECTED] 1 package.json file(s) with malicious npm dependency found
  - /Users/yourname/projects/my-app/package.json: Malicious npm package(s): tailwindcss-style-animate
```

`v1` = original March 2026 variant. `v2` = rotated April 2026 variant (`Cot%3t=shtP`). A file showing both labels has been re-infected. The final summary shows a count of infected files and repositories.

---

## What to do if you're infected

If the scanner finds anything, work through these steps:

1. **Remove the payload from infected config files.** Open the flagged file in a text editor. Scroll past the legitimate config — after the real `export default` line you will see hundreds of blank lines followed by a large block of obfuscated JavaScript. Delete everything from the first blank line after the real config to the end of the file.

2. **Delete `temp_auto_push.bat` and `config.bat`** from any affected repositories.

3. **Clean up `.gitignore`.** Remove any lines containing `config.bat` or `temp-auto.bat`.

4. **Rotate all secrets.** Treat every `.env` variable, API key, and database credential that existed in an affected project as compromised and rotate them immediately.

5. **Remove any malicious npm packages.** If the scanner flagged a `package.json`, uninstall the offending package:

   ```bash
   npm uninstall tailwindcss-style-animate tailwind-mainanimation tailwind-autoanimation tailwindcss-typography-style tailwindcss-style-modify tailwind-animationbased tailwindcss-animate-style
   ```

   Then delete `node_modules` and run `npm install` fresh.

6. **Check `.vscode/tasks.json`.** If the scanner flagged a tasks.json, delete the entire `.vscode/tasks.json` file unless you added it yourself. If a recruiter sent you a project to complete as a test, treat the whole repo as compromised — do not re-open it in VS Code.

7. **Notify anyone who cloned affected repositories.** Anyone who ran `npm install` or a build on an infected version of your repo may have executed the payload on their own machine.

8. **Force-push clean versions to GitHub** after removing the infected files and committing the clean state.

---

## Indicators of compromise (IOCs)

If you want to check manually before running the scanner:

**Malicious npm packages (all 7 known):**

- `tailwindcss-style-animate` — primary ShoeVista template dependency
- `tailwind-mainanimation`
- `tailwind-autoanimation`
- `tailwindcss-typography-style`
- `tailwindcss-style-modify`
- `tailwind-animationbased`
- `tailwindcss-animate-style`

**Campaign markers inside infected files:**

Original variant (March 2026):

```
("rmcej%otb%",2857687)
global['!'] = '7-1786'
global['!'] = '8-270-2'
```

Rotated variant (April 2026 — active evasion of YARA rule):

```
("Cot%3t=shtP",1111436)
global['_V'] = '8-st1'  (through '8-st59')
```

**Vercel-hosted C2 subdomains (TasksJacker vector):**

- `260120.vercel.app`
- `default-configuration.vercel.app`
- `vscode-settings-bootstrap.vercel.app`
- `vscode-settings-config.vercel.app`
- `vscode-bootstrapper.vercel.app`
- `vscode-load-config.vercel.app`

**StakingGame fake-interview template UUID:**

```
e9b53a7c-2342-4b15-b02d-bd8b8f6a03f9
```

Found in `.vscode/tasks.json` under `projectInfo.uuid`. If this UUID appears in a repo, the folder is a weaponized take-home test.

**Blockchain C2 endpoints:**

- `api.trongrid.io` (TRON — primary)
- `fullnode.mainnet.aptoslabs.com` (Aptos — fallback)
- `bsc-dataseed.binance.org` / `bsc-rpc.publicnode.com` (BSC)

**Infected file signature:**

- File: `postcss.config.mjs` (or `.js`, `.cjs`) — most common
- Also: `tailwind.config.js`, `eslint.config.mjs`, `next.config.mjs`, `vite.config.*`, `webpack.config.js`, `App.js`, `index.js`
- Size: ~5,500 bytes (a normal postcss config is under 200 bytes)
- Pattern: large block of blank lines after `export default config;`, followed by obfuscated JavaScript
