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
# `qualor-entrypoint` is the image's own, with its last line pointed at the stub.
# fix/action.yml is a composite action that runs on the runner: its three steps are run here in the
# scanner image (glibc) with a recording stub for the binary, the docker step only being checked as text.
# Also runs shellcheck (koalaman/shellcheck:stable) on every script.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
# Git Bash: keep container paths such as /github/workspace as they are.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV
SCANNER=$(sed -n 's|^  image: docker://||p' "$here/action.yml")
DOTNET=$(sed -n 's|^  image: docker://||p' "$here/dotnet/action.yml")
FIXIMAGE=$(sed -n 's|^    default: ||p' "$here/fix/action.yml" | grep '^qualor/scanner:')
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
sed "s|^exec /usr/local/bin/qualor |exec qualor |" /usr/local/bin/qualor-entrypoint > /stub/qualor-entrypoint
grep -q "^exec qualor " /stub/qualor-entrypoint
chmod 755 /stub/qualor-entrypoint
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
(cd "$here" && tar -cf - action.yml entrypoint.sh dotnet fix test) |
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
  }
  const fix = yaml.load(fs.readFileSync("/src/fix/action.yml", "utf8")).runs;
  console.log("fix", fix.using === "composite" && fix.steps.length === 3 && fix.steps.every((s) => s.shell === "bash") ? "composite" : "different");
  const names = ["copy", "musl", "run"];
  fix.steps.forEach((s, i) => {
    fs.writeFileSync("/src/fix-" + names[i] + ".sh", s.run);
    console.log("fix-" + names[i], /${{/.test(s.run) ? "expression" : "plain", "env:" + Object.keys(s.env || {}).join(","));
  });' > "$tmp/yaml.log" 2>&1
docker run --rm -v "$P-src:/src" --entrypoint tar "$SCANNER" -cf - -C /src inline-root.sh inline-dotnet.sh fix-copy.sh fix-musl.sh fix-run.sh |
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
check "fix/action.yml is a composite action of three bash steps" has "$tmp/yaml.log" "fix composite"
for n in copy musl run; do
  check "fix step $n has no GitHub expression in its script" has "$tmp/yaml.log" "fix-$n plain"
done
check "the fix steps take their inputs through env" has "$tmp/yaml.log" "fix-run plain env:QUALOR_URL,QUALOR_TOKEN,QUALOR_PROJECT_KEY,FIX_ARGS"
check "the token is set for the last step only" [ "$(grep -c 'QUALOR_TOKEN' "$here/fix/action.yml")" -eq 1 ]
check "fix/action.yml uses $FIXIMAGE" [ "$FIXIMAGE" = qualor/scanner:0.17.0 ]
check "the copy step: docker create, cp, rm" sh -c "grep -q 'docker create' '$tmp/fix-copy.sh' && grep -q 'docker cp' '$tmp/fix-copy.sh' && grep -q 'docker rm' '$tmp/fix-copy.sh' && grep -q '/usr/local/bin/qualor' '$tmp/fix-copy.sh'"
check "action.yml uses $SCANNER" [ "$SCANNER" = qualor/scanner:0.17.0 ]
check "dotnet/action.yml uses $DOTNET" [ "$DOTNET" = qualor/scanner-dotnet:0.17.0 ]

echo "== shellcheck"
for s in entrypoint.sh dotnet/entrypoint.sh test/run.sh test/stub/qualor test/stub/dotnet ../fix-copy.sh ../fix-musl.sh ../fix-run.sh; do
  f=$here/$s
  case $s in ../fix-*) f=$tmp/${s#../} ;; esac
  if docker run --rm -i "$SHELLCHECK" -s sh - < "$f" > "$tmp/sc.log" 2>&1; then
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
check "arguments" same "$tmp/out/calls" "qualor [scan] [--server-url] [$URL] [--project-key=acme/demo] [--config] [ci/qualor.yml] [--no-wait] [--sarif] [osv.sarif] [--branch] [feature/x] [--coverage] [src/*.ts]"
check "the token reaches qualor on a file descriptor" same "$tmp/out/tokenfd-scan" "$TOKEN"
check "no QUALOR_TOKEN in the scan's environment" hasnt "$tmp/out/env-scan" "QUALOR_TOKEN="
check "INPUT_TOKEN removed" hasnt "$tmp/out/env-scan" "INPUT_TOKEN="
check "HOME=/tmp/qualor-home" has "$tmp/out/env-scan" "HOME=/tmp/qualor-home"
check "the vulnerability database cache defaults to the workspace" same "$tmp/out/trivy-scan" /github/workspace/.qualor/trivy
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
check "--dry-run without a token: no file descriptor" same "$tmp/out/tokenfd-scan" none

act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" -e INPUT_WAIT=true \
  -e QUALOR_TRIVY_CACHE_DIR=/tmp/my-trivy
check "a preset QUALOR_TRIVY_CACHE_DIR is kept" same "$tmp/out/trivy-scan" /tmp/my-trivy

echo "== scan-action: the cache directory in a checkout owned by another user"
# The scanner runs as node and cannot create .qualor/trivy in the runner's checkout: the workflow's
# "mkdir -p .qualor/trivy && chmod 0777 .qualor/trivy" step (README) does it as the runner.
prep "$SCANNER" none ro
act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" -e INPUT_WAIT=true
check "without the prepare step the scanner cannot write the cache" same "$tmp/out/cachewrite-scan" failed
docker run --rm -u 0 -v "$P-ws:/github/workspace" --entrypoint /bin/sh "$SCANNER" -c   'mkdir -p /github/workspace/.qualor/trivy && chmod 0777 /github/workspace/.qualor/trivy && chown 1001:1001 /github/workspace/.qualor'
act "$SCANNER" "$ROOT" -e "$SP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" -e INPUT_WAIT=true
check "with the prepared 0777 directory the scanner writes the cache" same "$tmp/out/cachewrite-scan" ok

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
qualor [dotnet] [end] [--server-url] [$URL] [--project-key=acme/demo] [--config] [qualor.yml] [--no-wait] [--sarif] [osv.sarif]"
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
# The scan runs on the copy, so a cache in the workspace would lie outside the scanned checkout and
# be trusted without a checksum: the scanner keeps its default cache in the temporary HOME.
check "the vulnerability database cache is left unset" same "$tmp/out/trivy-dotnet-end" unset
check "end gets the token on a file descriptor" same "$tmp/out/tokenfd-dotnet-end" "$TOKEN"
check "no QUALOR_TOKEN in end's environment" hasnt "$tmp/out/env-dotnet-end" "QUALOR_TOKEN="
check "git reads the checkout in end" same "$tmp/out/git-dotnet-end" ok
check "no C# warning in the dotnet action" hasnt "$tmp/log" "::warning::"
check "token not in the output" no_token "$tmp/log"

act "$DOTNET" "$DN" -e "$DP" -e "INPUT_SERVER-URL=$URL" -e "INPUT_TOKEN=$TOKEN" -e INPUT_WAIT=true \
  -e QUALOR_TRIVY_CACHE_DIR=/tmp/my-trivy
check "dotnet: a preset QUALOR_TRIVY_CACHE_DIR is kept" same "$tmp/out/trivy-dotnet-end" /tmp/my-trivy

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

echo "== fix: the sub-action's steps on the runner"
# The binary is the recording stub, copied to $RUNNER_TEMP/qualor as the copy step would.
FIXPRE='mkdir -p /tmp/rt && cp /stub/qualor /tmp/rt/qualor'
{ echo "$FIXPRE"; cat "$tmp/fix-run.sh"; } > "$tmp/fix-go.sh"
prep "$SCANNER" none ro
act "$SCANNER" "$tmp/fix-go.sh" -e "$SP" -e RUNNER_TEMP=/tmp/rt -e "QUALOR_URL=$URL" -e "QUALOR_TOKEN=$TOKEN"   -e "QUALOR_PROJECT_KEY=acme/demo" -e "FIX_ARGS=--max 3  --timeout 1h *"
check "exit 0" status_is 0
check "arguments: split at blanks, no file name expands" same "$tmp/out/calls" "qualor [fix] [--max] [3] [--timeout] [1h] [*]"
check "the token and the server reach the binary" has "$tmp/out/env-fix" "QUALOR_TOKEN=$TOKEN"
check "the server URL reaches the binary" has "$tmp/out/env-fix" "QUALOR_URL=$URL"
check "the project key reaches the binary" has "$tmp/out/env-fix" "QUALOR_PROJECT_KEY=acme/demo"
check "token not in the output" no_token "$tmp/log"
# shellcheck disable=SC2016 # the substitution must stay unexpanded
act "$SCANNER" "$tmp/fix-go.sh" -e "$SP" -e RUNNER_TEMP=/tmp/rt -e "QUALOR_URL=$URL" -e "QUALOR_TOKEN=$TOKEN"   -e QUALOR_PROJECT_KEY= -e 'FIX_ARGS=; touch /out/injected $(touch /out/injected2)'
check "an empty project key is not passed on" hasnt "$tmp/out/env-fix" "QUALOR_PROJECT_KEY"
check "args never reach a shell as code" missing "$tmp/out/injected"
check "args never expand a substitution" missing "$tmp/out/injected2"
prep "$SCANNER" none ro
act "$SCANNER" "$tmp/fix-go.sh" -e "$SP" -e RUNNER_TEMP=/tmp/rt -e "QUALOR_URL=$URL" -e "QUALOR_TOKEN=$TOKEN"   -e QUALOR_PROJECT_KEY= -e FIX_ARGS= -e STUB_EXIT=4
check "exit code of qualor fix (4)" status_is 4
check "no arguments: plain qualor fix" same "$tmp/out/calls" "qualor [fix]"
prep "$SCANNER" none ro
act "$SCANNER" "$tmp/fix-musl.sh"
check "glibc image: the musl check passes" status_is 0
{ echo 'touch /lib/ld-musl-x86_64.so.1'; cat "$tmp/fix-musl.sh"; } > "$tmp/fix-musl-on.sh"
act "$SCANNER" "$tmp/fix-musl-on.sh" -u 0
check "musl image: exit 2" status_is 2
check "musl image: the error says why" has "$tmp/log" "::error::qualor fix needs a glibc image (Debian, Ubuntu, RHEL); this image uses musl"

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
