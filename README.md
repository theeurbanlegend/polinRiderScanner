# Polinrider Malware Cleaner

A cleaner script that enables you to "undo" a change caused by an unintended force push remotely, with suitable filters to help pinpoint where and how the rollback should occur.

## Table of contents

- [Repo structure](#repo-structure)
- [Prerequisites](#prerequisites)
  - [a) Installation guide](#a-installation-guide)
  - [b) Technical understanding](#b-technical-understanding)
- [Usage](#usage)
  - [a) Flags used](#a-flags-used)
  - [b) Best practices and procedure](#b-best-practices-and-procedure)

## Repo structure

The repo is organised as follows:

1. [`polinrider-cleanup.sh`](./polinrider-cleanup.sh): The main script that is drafted for linux systems.
2. [`polinrider-cleanup.ps1`](./polinrider-cleanup.ps1): This is the cleanup script ported from the bash script for windows systems.
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
   chmod u+x ./polinRiderScanner/polinrider-cleanup.sh
   ```

   - For Windows

   ```ps1
   cd polinRiderScanner
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\polinrider-cleanup.ps1 -Help
   ```

3. Run the script as per the docs. This can be found by running `-h` or `--help`, or passing the args as per this documentation.

   - For linux and MacOS

   ```bash
   ./polinRiderScanner/polinrider-cleanup.sh -h
   ```

   - For Windows

   ```ps1
   .\polinrider-cleanup.ps1 -Help
   ```

### b) Technical understanding

> [!NOTE]
> This section is collapsable as its not inherently needed to understand how to use the script, but if your curious of how it works and how different it is from v1
> Feel free to skip to the next section if this is not your field of interest.

Initially, this script was known as the `polinrider scanner` since we were using reported signatures from the [OpenSourceMalware PolinRider report](https://github.com/OpenSourceMalware/PolinRider). This included the following, though the thought process is best explained in the [v1 README](/v1.0/README.md#what-the-scanner-checks):

- `package.json` malicious package entries.
- Bat file entries in .gitignore, for windows persistense.
- Payload signature in all associated config files known to be preferred by the attacker.
- vscode files that automate extension download and execution via the debugger.
- weird font files in the repo that contain the payload snippet.

While this worked best at the time, it meant that we had to keep ourselves updated with any recent developments on how the PolinRider malware has changed over time. This includes being familiar with any new updates in terms of functionality, signatures and payload storage, which can lead to issues in case a patched version of it affects a repo long before it being reported or the team being aware of the script being updated.

It was also a bit more manual, where you had to know where you're running the script, approve of given changes and confirm if the reported changes have all been applied. Thus, for this version, extra effort was put into _**automating cleanup**_, so as to recover the repo from the malware as fast as possible rather than scanning for indicators of compromise.

This is made possible by using github's source of repo activity programmatically via the API to get the latest state right before the change, and resetting the repo to that point, akin to how [git reflog](https://www.atlassian.com/ru/git/tutorials/rewriting-history/git-reflog) can be used to recover a repo's branch from a force push locally💡.

Given the malware uses force pushes to make unsigned edits of prior commits to the repo, we have to use a more permanent contract as commit history is easily editable. However, in turn given we are rewriting history ourselves via the script, extra precautions have been set up:

- _**Using prompts**_ to confirm changes before proceeding.
- Displaying _**brief diffs**_ between the branch in question remotely and the commit after the force push, to indicate whether any activity has taken place.
- Making use of _**temp folders**_ to host git changes to the local repo, thus ensuring any system clones with their own progress remain untouched.

That being said, there's still some guidelines on how to use the script and how to understand it, best explained in the [usage](#usage) section.

> [!TIP]
> Given it restores branches to a given state prior to the force push, you can use it as some sort of recovery system outside polinrider in a script.
> Whatever floats your boat, so long as you use it knowing how best to run it

# Usage

The usage of the script can be described by what [flags it uses](#a-flags-used) and [best practices](#b-best-practices-and-procedure) to follow during usage.

### a) Flags used

This is described via the `-h` or `--help` flag as well, all flags are _**optional**_.

1.  `-b <branches>`, `--branches=<branches>`: The specific comma-separated list of branches to perform the operation on.
    > Defaults to all affected branches.
2.  `-a <actor>`, `--actor=<actor>`: The github username to look out for.
    > Defaults to current logged in user.
3.  `-r <repo>`, `--repo=<repo>`: The repo to work on.
    > Defaults to current repo's origin. Must be in the format owner/repo
4.  `-t <time-period>`, `--time-period=<time-period>`: The time-period of the force pushes in the branches to filter when calling the API. Can be `day`, `week`, `month`, `quarter`, `year`. This can be used when you're sure of when the force pushes occur, thus you want to get a subsect of them in that period from the API rather than calling for all force pushes, saving time and bandwidth.
5.  `-s <date>`, `--since=<date>`: Filter the response from the API to all force pushes beyond this date. It is _**inclusive**_ and must be in YYYY-MM-DD format.
    > [!NOTE] Its in local time
6.  `-u <date>`, `--until=<date>`: Filter the response from the API to all force pushes before this date. It is _**inclusive**_ and must be in YYYY-MM-DD format.
    > [!NOTE] Its in local time
7.  `-h`, `--help`: Show this guide

### b) Best practices and procedure

1. Ensure you _**target the repo you have access to**_ , if you're inside the repo folder locally the default will sort you out though preferrably, pass it as an arg
2. Pass the other options that suit your case. The default behaviour is to look for _**all latest force pushes owned by you across all branches**_ but depending on your case, this could be different
3. Run the script, and follow the prompts. At some point you might be notified of a drift between when the force push occured and the latest state of the remote branch, this signals activity in a branch and as such a brief diff stat is provided. _**Kindly review it**_ and choose to proceed if you are ok with the force push.
4. Once the script is done, go to your local repo if any and _**ensure active branches point to the ref remotely**_, this could be done by [git fetch](https://www.atlassian.com/ru/git/tutorials/syncing/git-fetch), [git pull](https://www.atlassian.com/ru/git/tutorials/syncing/git-pull) or [git rebase](https://www.atlassian.com/ru/git/tutorials/rewriting-history/git-rebase).
5. If your issue was fixing a hiccup from a given point of force push, all is well at this point, however if you were affected by the polinrider malware the cleaner restores the selected remote branches to an earlier commit. It is not a complete malware-removal procedure. Local machines, credentials,
6. dependencies, caches, secrets, and untracked files require separate cleanup..
7. _**Reinstall dev packages**_ in the local repo, since the malware entries are cleared from the lockfile if any, we need to rerun the installation to clear them from the `node_modules` folder or cache.
8. _**Clear unknown files**_, it might be the case that there were files added in the .gitignore by the malicious actor, which after updating local with the state before persist in your worktree as `untracked files`. Delete those that you don't recognise as keeping them around might cause a re-entry, say batch files for instance.
9. _**Rotate env secrets**_, given the malware might have accessed your `.env` secrets and local dev keys, generate new ones to avoid them affecting any real connected services. If you're using mocks it wouldn't hurt to run this nonetheless.
10. _**Fix github credentials**_, based on your editor of choice, especially vscode and its clones like cursor, you might have had access tokens to your authenticated editor read and used later on for more force pushes. To avoid this head over to [gh's apps page](https://github.com/settings/installations) and refresh any microsoft associated connections, plus those that you might not be familiar with. If you're account made the force push you can sort the connections by recency to confirm this, given any used within the last week onward is a culprit.

> [!TIP]
> By "force push", as we discussed in the [technical breakdown](#b-technical-understanding), what we mean is a force push by activity, not by commit, as one can easily impersonate a commit hash, commit message or commit author.
> To really get the culprit, go to the "reflog" of your repo, ie the activity tab, to get the force push in question. This can't be faked as it interacts with the authenticated github account, and not the git config details during the commit.
> As a plus you can use the date to filter down when the commit happened via the --since, --until and --time-period flags
