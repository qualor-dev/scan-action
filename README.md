# Qualor scan

Runs [Qualor](https://qualor.dev) code quality and security analysis in GitHub Actions. The action
scans your repository with the `qualor/scanner` image, uploads the analysis to your own Qualor
server and fails the step when the quality gate fails.

On pull requests, Qualor's GitHub App posts a check run, review comments on the changed lines and a
summary comment, and with AI review on, the AI reviewer's threads. You connect the App once in Qualor; the workflow itself needs no write
permission. See [qualor.dev/docs/github](https://qualor.dev/docs/github).

## Usage

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0
    persist-credentials: false
    ref: ${{ github.event.pull_request.head.sha || github.sha }}
- uses: qualor-dev/scan-action@v0.15
  with:
    server-url: ${{ vars.QUALOR_URL }}
    token: ${{ secrets.QUALOR_TOKEN }}
```

In the repository (or organisation), under **Settings → Secrets and variables → Actions**, add:

| Kind     | Name           | Value                                                        |
| -------- | -------------- | ------------------------------------------------------------ |
| Variable | `QUALOR_URL`   | Your Qualor server, for example `https://qualor.example.com` |
| Secret   | `QUALOR_TOKEN` | A project analysis token from Qualor                         |

The project key defaults to the repository (`owner/repo`); set `project.key` in `qualor.yml` or the
`project-key` input to use another one.

## A complete workflow

Save this as `.github/workflows/qualor.yml`:

```yaml
name: qualor
on:
  pull_request:
  push:
    branches: [main] # your default branch
    tags: ['**'] # a tag push records a version
permissions:
  contents: read
jobs:
  qualor:
    # Pull requests from forks get no secrets, so they are skipped.
    if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
          persist-credentials: false
          ref: ${{ github.event.pull_request.head.sha || github.sha }}
      # Install dependencies (JavaScript, TypeScript, Go) or build (Java) here, before the scan.
      - uses: qualor-dev/scan-action@v0.15
        with:
          server-url: ${{ vars.QUALOR_URL }}
          token: ${{ secrets.QUALOR_TOKEN }}
```

On a tag push, the scan records a [version](https://qualor.dev/docs/releases) of the project instead,
and applies no quality gate.

Why the checkout looks like this:

- `ref` checks out the **pull request's head**, not GitHub's merge commit, so review comments land on the
  pull request's own lines.
- `fetch-depth: 0` gives the full history, from which Qualor works out the new code.
- `persist-credentials: false` keeps the job's GitHub token out of `.git/config`, where the
  analysed code could read it.

To block merges on the gate, require the status check `qualor` (this job) or `qualor/<project key>`
(the App's check run) in a branch protection rule or ruleset.

## Inputs

| Input         | Default  | Description                                                                                                   |
| ------------- | -------- | ------------------------------------------------------------------------------------------------------------- |
| `server-url`  | required | Your Qualor server, for example `https://qualor.example.com`.                                                 |
| `token`       | required | A project analysis token. Pass it from a secret.                                                              |
| `project-key` |          | The Qualor project key. Default: `project.key` in `qualor.yml`, else the repository (`owner/repo`).           |
| `config`      |          | The path of `qualor.yml`, when it is not at the repository root.                                              |
| `wait`        | `true`   | Wait for the quality gate and fail the step when it fails. `false` uploads and passes.                        |
| `args`        |          | More `qualor scan` options, separated by spaces, for example `--sarif osv.sarif`. Quotes are not interpreted. |

The step passes or fails with `qualor scan`: it fails when the gate fails (with `wait: true`), when
an analyzer that `qualor.yml` marks as required fails, or when the upload is refused (for example a
wrong or revoked token). The options are listed at
[qualor.dev/docs/cli](https://qualor.dev/docs/cli).

The action runs on Linux runners (`ubuntu-latest` or a self-hosted Linux runner with Docker).

The scanner runs as its own user and cannot write into the checkout, so an option that writes a
file (such as `--output`) needs a path under `/tmp`, for example `--output /tmp/report.json.gz`.
Such a file is gone when the step ends.

## Cache the vulnerability database

Qualor takes the vulnerability database from your server, and a cache saves the download on later
runs. The action is a Docker action and cannot run `actions/cache` itself, so put these three steps
around it:

```yaml
- uses: actions/cache/restore@caa296126883cff596d87d8935842f9db880ef25 # v5.1.0
  with:
    path: .qualor/trivy
    key: qualor-trivy-db-${{ github.run_id }}
    restore-keys: qualor-trivy-db-
- run: mkdir -p .qualor/trivy && chmod 0777 .qualor/trivy
- uses: qualor-dev/scan-action@v0.15
  with:
    server-url: ${{ vars.QUALOR_URL }}
    token: ${{ secrets.QUALOR_TOKEN }}
- uses: actions/cache/save@caa296126883cff596d87d8935842f9db880ef25 # v5.1.0
  if: always() && hashFiles('.qualor/trivy/server.json') != ''
  with:
    path: .qualor/trivy
    key: qualor-trivy-db-${{ hashFiles('.qualor/trivy/server.json') }}
```

The `mkdir` step is needed because the action runs as its own user, which cannot create a
directory in your checkout.

A cache inside the workspace is safe: the scanner uses the archive only after the Qualor server
confirms its checksum.

The action uses `.qualor/trivy` in the workspace unless `QUALOR_TRIVY_CACHE_DIR` is set.

## C#

Qualor analyses C# inside your build, so C# projects use the `dotnet` action instead. It runs
`qualor dotnet begin`, your build and `qualor dotnet end` in the `qualor/scanner-dotnet` image:

```yaml
- uses: qualor-dev/scan-action/dotnet@v0.15
  with:
    server-url: ${{ vars.QUALOR_URL }}
    token: ${{ secrets.QUALOR_TOKEN }}
    build-command: dotnet build MySolution.sln --no-incremental
```

It takes the same inputs plus `build-command` (default `dotnet build --no-incremental`; keep
`--no-incremental`, so every project is compiled and analysed). When the build fails, the step
fails and nothing is uploaded. The main action warns when it finds C# files.

The C# action builds and analyses a copy of the checkout, with its history, so the build's outputs
(`bin/`, `obj/`) do not land in the workspace, and a very large checkout takes a little longer to
start. Files that `args` refers to (such as a SARIF file) are copied with it when earlier steps
wrote them into the workspace. Because it scans a copy, the C# action keeps no vulnerability
database cache and downloads the database on each run: leave the cache steps out. Do not point
`QUALOR_TRIVY_CACHE_DIR` into the workspace for the C# action: the scan runs on a copy, so the
directory would be trusted without the check the main action gets.

The token is given to `qualor dotnet end` only and kept out of the build's environment. The build
still runs your repository's code (MSBuild targets, source generators) in the same container, so it
could read the token. The token can only upload and read analyses of its own project. If that is
not acceptable, use the workflow template that keeps the token in a separate step:
[qualor-dotnet.yml](https://github.com/qualor-dev/qualor/blob/main/integrations/github/qualor-dotnet.yml).

## Fix pull requests

`qualor-dev/scan-action/fix` runs `qualor fix`, which opens pull requests that bump vulnerable
dependencies. It runs on the runner, after your own setup steps, so it uses your package manager and
your registry credentials. It copies the `qualor` binary out of the scanner image, so it needs a
glibc runner (Ubuntu or Debian, not Alpine) and Docker:

```yaml
name: qualor-fix
on:
  push:
    branches: [main] # your default branch
  schedule:
    - cron: '17 3 * * *' # daily, so fixes are picked up every day
permissions:
  contents: read
jobs:
  fix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
          persist-credentials: false
      # Your own setup comes first: setup-node, setup-java, setup-go, registry login, ...
      - uses: actions/setup-node@v5
        with:
          node-version: 22
      - uses: qualor-dev/scan-action/fix@v0.16
        with:
          server-url: ${{ vars.QUALOR_URL }}
          token: ${{ secrets.QUALOR_TOKEN }}
```

The workflow needs no write permission: the pull requests are opened by Qualor's GitHub App.

| Input           | Default                 | Description                                                                                                  |
| --------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------ |
| `server-url`    | required                | Your Qualor server, for example `https://qualor.example.com`.                                                |
| `token`         | required                | A project analysis token. Pass it from a secret.                                                             |
| `project-key`   |                         | The Qualor project key. Default: `project.key` in `qualor.yml`, else the repository (`owner/repo`).          |
| `scanner-image` | `qualor/scanner:0.16.0` | The image the `qualor` binary is copied from. Use a mirror here if you cannot pull from Docker Hub.         |
| `args`          |                         | More `qualor fix` options, for example `--max 3`. Split at blanks on purpose: quotes are not interpreted. |

The token reaches only the step that runs `qualor fix`, and is never written to `GITHUB_ENV`.
The step passes or fails with `qualor fix`.

## Pull requests from forks

GitHub gives no secrets to workflows of pull requests from forks, so the scan could not upload; the
workflow above skips them. Do not switch to `pull_request_target` to get around this: it would run
the fork's code with your token.

## Your own image or a registry mirror

The action runs the public `qualor/scanner` image from Docker Hub. To run your own copy (a private
registry or a mirror), use the workflow template instead:
[qualor.yml](https://github.com/qualor-dev/qualor/blob/main/integrations/github/qualor.yml), described
in [qualor.dev/docs/github](https://qualor.dev/docs/github).

## Versions

The action's version follows Qualor's: `v0.15.1` runs `qualor/scanner:0.15.1`. `@v0.15` follows
the 0.15 patch releases and `@v0` the latest release. Pick the version that matches your Qualor
server, or pin a full version (`@v0.15.1`) to control every update.

## Licence

MIT, see [LICENSE](LICENSE).
