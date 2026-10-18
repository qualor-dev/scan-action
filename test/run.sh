#!/bin/sh
# Local test harness for both actions (needs Docker; not a workflow).
#
#   sh test/run.sh
#
# Runs each action's inline script (read from its action.yml with a YAML parser) the way GitHub
# runs a docker:// action: as the image's user, `sh -c <script>`, the checkout at
# /github/workspace owned by another user (1001, the runner's), HOME=/github/home not writable,
# and the inputs as INPUT_<NAME> variables with the hyphens kept. `qualor` and `dotnet` are
# recording stubs (test/stub), except in the last case, which runs the real scanner (--dry-run).
# Also runs shellcheck (koalaman/shellcheck:stable) on every script.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
# Git Bash: keep container paths such as /github/workspace as they are.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV
SCANNER=$(sed -n 's|^  image: docker://||p' "$here/action.yml")
DOTNET=$(sed -n 's|^  image: docker://||p' "$here/dotnet/action.yml")
SHELLCHECK=koalaman/shellcheck:stable
TOKEN=qlr_test_5ecret_70ken_v4lue
URL=https://qualor.example.com
P=qsa-test-$$
tmp=$(mktemp -d)
passed=0
failed=0

cleanup() {
  for v in src ws home out stub; do docker volume rm -f "$P-$v" > /dev/null 2>&1; done
  rm -rf "$tmp"
}
trap cleanup EXIT

ok() {
  passed=$((passed + 1))
  echo "  ok   $1"
}
ko() {
  failed=$((failed + 1))
  echo "  FAIL $1"
}
check() { # check <description> <command...>
  d=$1
  shift
  if "$@"; then ok "$d"; else ko "$d"; fi
}
has() { grep -qF -- "$2" "$1" 2> /dev/null; }
hasnt() { ! grep -qF -- "$2" "$1" 2> /dev/null; }
missing() { [ ! -e "$1" ]; }
same() { [ "$(cat "$1" 2> /dev/null)" = "$2" ]; }
status_is() { [ "$code" -eq "$1" ]; }
no_token() { ! grep -rqF -- "$TOKEN" "$@" 2> /dev/null; }

# The fixture checkout: a git repository with a TypeScript file (and a C# file with `cs`),
# owned by 1001; `ro` leaves it unwritable for the image's user (as on GitHub), `rw` does not.
# shellcheck disable=SC2016 # expanded by the container's shell
PREP='set -e
find /github/workspace /out -mindepth 1 -delete
mkdir -p /stub
cp /src/test/stub/qualor /src/test/stub/dotnet /stub/
chmod 755 /stub/qualor /stub/dotnet
cd /github/workspace
git init -q -b main
git config user.email test@example.com
git config user.name Test
mkdir src
printf "export function add(a: number, b: number): number {\n  return a + b;\n}\n" > src/add.ts
printf "{\"name\": \"fixture\", \"version\": \"1.0.0\", \"private\": true}\n" > package.json
if [ "$1" = cs ]; then printf "public class Greeter { }\n" > src/Greeter.cs; fi
git add -A
git -c commit.gpgsign=false commit -q -m init
git rev-parse HEAD > /out/sha
printf "{\"repository\": {\"default_branch\": \"main\"}}\n" > /out/event.json
chown -R 1001:1001 /github/workspace /github/home
chmod 755 /github/home
if [ "$2" = ro ]; then chmod -R go-w /github/workspace; else chmod -R a+w /github/workspace; fi
chmod 777 /out
chmod 644 /out/sha /out/event.json'

prep() { # prep <image> <cs|none> <ro|rw>
  docker run --rm -u 0 -v "$P-src:/src" -v "$P-ws:/github/workspace" -v "$P-home:/github/home" \
    -v "$P-out:/out" -v "$P-stub:/stub" --entrypoint /bin/sh "$1" -c "$PREP" prep "$2" "$3" \
    > "$tmp/prep.log" 2>&1 || {
    cat "$tmp/prep.log"
    echo "prep failed"
    exit 1
  }
}

# act <image> <script> [docker options...]: run the script as GitHub runs the action; the output
# goes to $tmp/log, the exit code to $code, the stub records to $tmp/out.
act() {
  img=$1
  script=$2
  shift 2
  docker run --rm --workdir /github/workspace \
    -v "$P-ws:/github/workspace" -v "$P-home:/github/home" -v "$P-out:/out" -v "$P-stub:/stub" \
    -e HOME=/github/home -e GITHUB_WORKSPACE=/github/workspace -e GITHUB_ACTIONS=true -e CI=true \
    "$@" --entrypoint /bin/sh "$img" -c "$(cat "$script")" > "$tmp/log" 2>&1
  code=$?
  rm -rf "$tmp/out"
  mkdir -p "$tmp/out"
  docker run --rm -v "$P-out:/out" --entrypoint tar "$img" -cf - -C /out . | tar -xf - -C "$tmp/out"
}

stubpath() { echo "PATH=/stub:$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n 's/^PATH=//p')"; }

for v in src ws home out stub; do docker volume create "$P-$v" > /dev/null; done
(cd "$here" && tar -cf - action.yml entrypoint.sh dotnet test) |
  docker run --rm -i -u 0 -v "$P-src:/src" --entrypoint tar "$SCANNER" -xf - -C /src

echo "== the inline scripts"
docker run --rm -u 0 -v "$P-src:/src" --entrypoint node "$SCANNER" -e '
  const yaml = require("/opt/qualor/weblint/node_modules/js-yaml");
  const fs = require("fs");
  for (const [a, s, o] of [["action.yml", "entrypoint.sh", "root"], ["dotnet/action.yml", "dotnet/entrypoint.sh", "dotnet"]]) {
    const runs = yaml.load(fs.readFileSync("/src/" + a, "utf8")).runs;
    const ok = runs.using === "docker" && runs.entrypoint === "/bin/sh" && runs.args.length === 2 && runs.args[0] === "-c";
    fs.writeFileSync("/src/inline-" + o + ".sh", runs.args[1]);
    console.log(o, ok && runs.args[1] === fs.readFileSync("/src/" + s, "utf8") ? "same" : "different");
  }' > "$tmp/yaml.log" 2>&1
docker run --rm -v "$P-src:/src" --entrypoint tar "$SCANNER" -cf - -C /src inline-root.sh inline-dotnet.sh |
  tar -xf - -C "$tmp"
check "action.yml runs entrypoint.sh inline" has "$tmp/yaml.log" "root same"
check "dotnet/action.yml runs dotnet/entrypoint.sh inline" has "$tmp/yaml.log" "dotnet same"
for s in "$here/entrypoint.sh" "$here/dotnet/entrypoint.sh"; do
  n=${s#"$here"/}
  # shellcheck disable=SC1003
  check "$n has no backslash (GitHub re-quotes docker args)" hasnt "$s" '\'
  # shellcheck disable=SC2016
  check "$n has no GitHub expression" hasnt "$s" '${{'
done
check "action.yml uses $SCANNER" [ "$SCANNER" = qualor/scanner:0.10.0 ]
check "dotnet/action.yml uses $DOTNET" [ "$DOTNET" = qualor/scanner-dotnet:0.10.0 ]

echo "== shellcheck"
for s in entrypoint.sh dotnet/entrypoint.sh test/run.sh test/stub/qualor test/stub/dotnet; do
  if docker run --rm -i "$SHELLCHECK" -s sh - < "$here/$s" > "$tmp/sc.log" 2>&1; then
    ok "shellcheck $s"
  else
    ko "shellcheck $s"
    cat "$tmp/sc.log"
  fi
done

ROOT=$tmp/inline-root.sh
DN=$tmp/inline-dotnet.sh
SP=$(stubpath "$SCANNER")
DP=$(stubpath "$DOTNET")

echo "== scan-action: every input"
prep "$SCANNER" none ro
act "$SCANNER" "$ROOT" -e "$SP" -e GIT_CONFIG_NOSYSTEM=1 -e "INPUT_SERVER-URL=$URL" \
  -e "INPUT_TOKEN=$TOKEN" -e "INPUT_PROJECT-KEY=acme/demo" -e INPUT_CONFIG=ci/qualor.yml -e INPUT_WAIT=false \
  -e "INPUT_ARGS=--sarif osv.sarif  --branch feature/x --coverage src/*.ts"
check "exit 0" status_is 0
check "arguments" same "$tmp/out/calls" "qualor [scan] [--server-url] [$URL] [--project-key] [acme/demo] [--config] [ci/qualor.yml] [--no-wait] [--sarif] [osv.sarif] [--branch] [feature/x] [--coverage] [src/*.ts]"
check "QUALOR_TOKEN set for the scan" has "$tmp/out/env-scan" "QUALOR_TOKEN=$TOKEN"
check "INPUT_TOKEN removed" hasnt "$tmp/out/env-scan" "INPUT_TOKEN="
check "HOME=/tmp/qualor-home" has "$tmp/out/env-scan" "HOME=/tmp/qualor-home"
check "safe.directory (key)" has "$tmp/out/env-scan" "GIT_CONFIG_KEY_0=safe.directory"
check "safe.directory (value)" has "$tmp/out/env-scan" "GIT_CONFIG_VALUE_0=*"
check "git reads the checkout of user 1001" same "$tmp/out/git-scan" ok
check "no C# warning without .cs files" hasnt "$tmp/log" "::warning::"
check "token not in the output" no_token "$tmp/log"

echo "== scan-action: defaults, C# files, a failing gate"
prep "$SCANNER" cs ro
act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" \
  -e "INPUT_PROJECT-KEY=" -e INPUT_CONFIG= -e INPUT_WAIT=true -e INPUT_ARGS= -e STUB_EXIT=1
check "exit code of qualor scan (1)" status_is 1
check "arguments" same "$tmp/out/calls" "qualor [scan] [--server-url] [$URL]"
check "C# warning names the dotnet action" has "$tmp/log" "::warning::This repository has C# files. Qualor analyses C# inside its build: use qualor-dev/scan-action/dotnet"
check "token not in the output" no_token "$tmp/log"

echo "== scan-action: wrong inputs"
prep "$SCANNER" none ro
act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" -e INPUT_WAIT=maybe
check "wait: maybe fails (exit 2)" status_is 2
check "wait: maybe is reported" has "$tmp/log" "::error::The wait input must be true or false"
check "wait: maybe never runs qualor" missing "$tmp/out/calls"
check "token not in the output" no_token "$tmp/log"
act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=$URL" -e INPUT_TOKEN= -e INPUT_WAIT=true
check "empty token fails (exit 2)" status_is 2
check "empty token is reported" has "$tmp/log" "::error::The token input is empty"
check "empty token never runs qualor" missing "$tmp/out/calls"
act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=" -e "INPUT_TOKEN=$TOKEN" -e INPUT_WAIT=true
check "empty server-url fails (exit 2)" status_is 2
check "empty server-url is reported" has "$tmp/log" "::error::The server-url input is empty"

act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=" -e "INPUT_TOKEN=" -e INPUT_WAIT=true \
  -e "INPUT_ARGS=--dry-run --output /out/r.json.gz"
check "--dry-run without server and token runs (exit 0)" status_is 0
check "--dry-run without server and token: arguments" same "$tmp/out/calls" "qualor [scan] [--dry-run] [--output] [/out/r.json.gz]"
check "--dry-run without a token: no QUALOR_TOKEN" hasnt "$tmp/out/env-scan" "QUALOR_TOKEN="

echo "== control: without the action's safe.directory git refuses the checkout"
# The image's /etc/gitconfig trusts every directory too; the cases above ignore it
# (GIT_CONFIG_NOSYSTEM=1), so they show that the action's own setting is enough.
docker run --rm --workdir /github/workspace -v "$P-ws:/github/workspace" -e HOME=/tmp \
  -e GIT_CONFIG_NOSYSTEM=1 --entrypoint git "$SCANNER" rev-parse HEAD > "$tmp/log" 2>&1
check "git as node, no safe.directory: dubious ownership" has "$tmp/log" "dubious ownership"

echo "== dotnet: begin, build, end"
prep "$DOTNET" cs ro
act "$DOTNET" "$DN" -e "$DP" -e GIT_CONFIG_NOSYSTEM=1 -e "INPUT_SERVER-URL=$URL" \
  -e "INPUT_TOKEN=$TOKEN" -e "INPUT_BUILD-COMMAND=dotnet build --no-incremental" \
  -e "INPUT_PROJECT-KEY=acme/demo" \
  -e INPUT_CONFIG=qualor.yml -e INPUT_WAIT=false -e "INPUT_ARGS=--sarif osv.sarif"
check "exit 0" status_is 0
check "begin, build, end in order, no abort" same "$tmp/out/calls" "qualor [dotnet] [begin] [--config] [qualor.yml]
dotnet [build] [--no-incremental]
qualor [dotnet] [end] [--server-url] [$URL] [--project-key] [acme/demo] [--config] [qualor.yml] [--no-wait] [--sarif] [osv.sarif]"
check "begin runs in the copy of the checkout" same "$tmp/out/pwd-dotnet-begin" /tmp/qualor-src
check "the build runs in the copy" same "$tmp/out/pwd-build" /tmp/qualor-src
check "end runs in the copy" same "$tmp/out/pwd-dotnet-end" /tmp/qualor-src
check "the copy is announced" has "$tmp/log" "Copying the checkout to /tmp/qualor-src"
check "nothing written in the checkout (no obj/, no .qualor/)" docker run --rm \
  -v "$P-ws:/github/workspace" --entrypoint /bin/sh "$DOTNET" -c \
  'test ! -e /github/workspace/obj && test ! -e /github/workspace/.qualor'
check "the token is not in begin's environment" no_token "$tmp/out/env-dotnet-begin"
check "the token is not in the build's environment" no_token "$tmp/out/env-build"
check "the build has HOME=/tmp/qualor-home" has "$tmp/out/env-build" "HOME=/tmp/qualor-home"
check "end has QUALOR_TOKEN" has "$tmp/out/env-dotnet-end" "QUALOR_TOKEN=$TOKEN"
check "git reads the checkout in end" same "$tmp/out/git-dotnet-end" ok
check "no C# warning in the dotnet action" hasnt "$tmp/log" "::warning::"
check "token not in the output" no_token "$tmp/log"

echo "== dotnet: a failing build"
prep "$DOTNET" cs ro
act "$DOTNET" "$DN" -e "$DP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" \
  -e "INPUT_BUILD-COMMAND=echo building; exit 7" -e "INPUT_PROJECT-KEY=" -e INPUT_CONFIG= \
  -e INPUT_WAIT=true -e INPUT_ARGS=
check "exit code of the build (7)" status_is 7
check "begin, then abort, never end" same "$tmp/out/calls" "qualor [dotnet] [begin]
qualor [dotnet] [abort]"
check "the build command ran" has "$tmp/log" "building"
check "the failure is reported" has "$tmp/log" "::error::The build failed (exit code 7)"
check "token not in the output" no_token "$tmp/log"

echo "== dotnet: a failing gate"
prep "$DOTNET" cs ro
act "$DOTNET" "$DN" -e "$DP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" \
  -e "INPUT_BUILD-COMMAND=dotnet build --no-incremental" -e INPUT_WAIT=true -e STUB_EXIT=1
check "exit code of end (1)" status_is 1
check "no abort after end" hasnt "$tmp/out/calls" "[abort]"
check "token not in the output" no_token "$tmp/log"

echo "== scan-action with the real scanner (--dry-run)"
prep "$SCANNER" none ro
sha=$(docker run --rm -v "$P-out:/out" --entrypoint cat "$SCANNER" /out/sha)
act "$SCANNER" "$ROOT" -e GIT_CONFIG_NOSYSTEM=1 -e "INPUT_SERVER-URL=" -e "INPUT_TOKEN=$TOKEN" \
  -e "INPUT_PROJECT-KEY=" -e INPUT_CONFIG= -e INPUT_WAIT=false -e "INPUT_ARGS=--dry-run --output /out/report.json.gz" \
  -e GITHUB_EVENT_NAME=push -e GITHUB_REF=refs/heads/main -e GITHUB_REF_NAME=main \
  -e GITHUB_REF_TYPE=branch -e "GITHUB_SHA=$sha" -e GITHUB_REPOSITORY=acme/demo \
  -e GITHUB_EVENT_PATH=/out/event.json
check "exit 0" status_is 0
[ "$code" -eq 0 ] || tail -n 30 "$tmp/log"
sed -n 's/^/       | /p' "$tmp/log" | grep -i 'warn' | head -n 10
if [ -f "$tmp/out/report.json.gz" ]; then
  gzip -dc "$tmp/out/report.json.gz" > "$tmp/report.json"
  ok "report written"
else
  ko "report written"
  : > "$tmp/report.json"
fi
check "report has the commit" has "$tmp/report.json" "$sha"
check "report has the branch" has "$tmp/report.json" '"main"'
check "report has the repository" has "$tmp/report.json" "acme/demo"
check "token not in the output" no_token "$tmp/log"
check "token not in the report" no_token "$tmp/report.json"

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
