#!/bin/sh
# qualor-dev/scan-action: runs `qualor scan` in the qualor/scanner image.
# action.yml runs this same text inline (`sh -c`), because GitHub does not mount the action's own
# directory into a docker:// image. Keep the two identical (test/run.sh checks it), and keep this
# text free of backslashes and of GitHub expressions (dollar sign, double brace).
set -u

fail() {
  echo "::error::$1"
  exit 2
}

# An input's value. GitHub names the variable INPUT_ plus the input name in upper case and keeps
# its hyphens (INPUT_SERVER-URL). sh can neither expand nor pass on such a name, so it is read from
# this shell's initial environment; a name without a hyphen falls back to the variable itself.
input() {
  v=$(sed -z -n "s/^INPUT_$1=//p" "/proc/$$/environ" 2>/dev/null)
  if [ -z "$v" ]; then
    v=$(printenv "INPUT_$(echo "$1" | sed 's/-/_/g')" || true)
  fi
  printf '%s' "$v"
}

# The image runs as the user node, which cannot write GitHub's /github/home, and the checkout
# belongs to the runner's user: give git and the scanner a home of their own and let git read the
# checkout, without writing any configuration file.
HOME=/tmp/qualor-home
export HOME
mkdir -p "$HOME"
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=safe.directory
GIT_CONFIG_VALUE_0='*'
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
cd "${GITHUB_WORKSPACE:-.}" || fail 'The workspace is missing: run actions/checkout before this step'

extra=$(input ARGS)
# With --dry-run in args nothing is uploaded, and the server and the token may be left out.
case " $extra " in
  *' --dry-run '*) dry=true ;;
  *) dry=false ;;
esac

url=$(input SERVER-URL)
[ -n "$url" ] || url=${QUALOR_URL:-}
[ -n "$url" ] || [ "$dry" = true ] || fail 'The server-url input is empty: set it to your Qualor server, for example https://qualor.example.com'

token=$(input TOKEN)
[ -n "$token" ] || token=${QUALOR_TOKEN:-}
[ -n "$token" ] || [ "$dry" = true ] || fail 'The token input is empty: pass a project analysis token from a secret (GitHub gives no secrets to pull requests from forks)'
unset INPUT_TOKEN QUALOR_TOKEN
if [ -n "$token" ]; then
  QUALOR_TOKEN=$token
  export QUALOR_TOKEN
fi
unset token

set --
[ -z "$url" ] || set -- --server-url "$url"
key=$(input PROJECT-KEY)
[ -z "$key" ] || set -- "$@" "--project-key=$key"
config=$(input CONFIG)
[ -z "$config" ] || set -- "$@" --config "$config"
case $(input WAIT) in
  '' | true | True | TRUE) ;;
  false | False | FALSE) set -- "$@" --no-wait ;;
  *) fail 'The wait input must be true or false' ;;
esac
# The args input is split at blanks, like a command line without quotes; no file names expand.
set -f
# shellcheck disable=SC2086
set -- "$@" $extra
set +f

if git ls-files -- '*.cs' 2>/dev/null | grep -q .; then
  echo '::warning::This repository has C# files. Qualor analyses C# inside its build: use qualor-dev/scan-action/dotnet for it (https://qualor.dev/docs/languages-and-analyzers#c)'
fi

exec qualor scan "$@"
