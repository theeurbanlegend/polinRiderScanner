# Polinrider Malware Cleaner

A cleaner script that enables you to "undo" a change caused by an unintended force push remotely, with suitable filters to help pinpoint where and how the rollback should occur.

## Repo structure

The repo is organised as follows:

1. [`polinrider-cleanup.sh`](./polinrider-cleanup.sh): The main script that is drafted for linux systems.
2. [`polinrider cleanup.ps1`](./polinrider-cleanup.ps1): This is the cleanup script ported from the bash script for windows systems.
3. [`v(previous_major_version)`](./v1.0/): The folder contains the scripts used prior to a major change. Currently it has the v1 forms of the cleanup scripts, similar to the current setup, plus a [README](./v1.0/README.md) on how to use it.

---

In terms of development, the following sequence is observed by the contributors:

- The scripts are released.
- If there is a bug, or a development feature to be introduced, we add it to the bash script.
- The bash script is ported to a powershell script, for windows users, before the final pull request merge.
- If there is a major change, say a major shift on how conflicts are handled or defaults, the current repo is packaged in a folder at the root and the 2 scripts added alongside it.

We try to follow the [semver](https://semver.org/) versioning system with our own twist 😄.

## Prerequisites

1. [_**Git**_](https://git-scm.com/install/): For version control, plus get the script.
2. [_**Github cli**_](https://github.com/cli/cli#installation): To interact with github's data via the API.
3. _**A terminal**_: Don't think a system comes without this lol, for windows we need powershell for the powershell script, while for linux and macOS we need a bash capable terminal.

### a) Installation guide

> [!NOTE]
> Anything in curly braces in this guide section is user provided, unless stated otherwise

1. Clone the repo via git. By default it clones it into `polinRiderScanner` folder in your working directory, but [as per the docs](https://git-scm.com/docs/git-clone) you can provide your own folder to clone in.

```bash
git clone https://github.com/theeurbanlegend/polinRiderScanner ${YOUR_DIR_PATH_IF_ANY}
```

2. Make the script executable. You can find it in the folder as from the prior step. In the case of this example that's gonna be the default, ie `polinRiderScanner`.

   - For linux and MacOS

   ```bash
   cd polinRiderScanner
   chmod ug+x ./polinRiderScanner/polinrider-cleanup.sh
   ```

   - For Windows

   ```ps1
   cd polinRiderScanner
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\polinrider-cleanup.ps1 -Help
    ```

3. Run the script as per the docs. This can be found by running `-h` or `--help`, or passing the args as per this documentation.

```bash
# Get help
./polinRiderScanner/polinrider-cleanup.sh -h
````

### b) Technical understanding

> [!NOTE]
> This section is collapsable as its not inherently needed to understand how to use the script, but if your curious of how it works and how different it is from v1
> Feel free to skip to the next section if this is not your field of interest.
