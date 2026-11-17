#!/bin/bash
# Asserts that build.sh produces a COMPLETE Docker build context from a clean
# checkout -- the state a Hugging Face Space, a CI runner, or a new machine
# starts from.
#
# It exists because three of the inputs the image needs are not in this
# repository: the classifier artifacts live in a Hugging Face model repo, and
# the S1-S4 scenario profiles came from the gitignored PPI_Digital-Interface/.
# A build on this machine passed by reading directories that only exist here.
#
# Run from the repo root:  bash dairy-api/verify_build_context.sh
# Exits non-zero and names every missing input.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Copy across only the files git tracks, at their current contents. That is what
# a clean checkout gets, and it deliberately leaves out untracked directories
# like MilkSpoilageClassifier/ and the gitignored legacy apps -- the ones whose
# presence on a development machine hides this whole class of failure.
# Working-tree contents rather than HEAD, so this can be iterated without
# committing first.
echo "Assembling a clean checkout from tracked files..."
mkdir -p "$WORK/repo"
( cd "$REPO_ROOT" && git ls-files -z | tar --null -cf - -T - ) \
    | ( cd "$WORK/repo" && tar -xf - ) || {
    echo "FAIL: could not assemble the clean checkout"; exit 1; }

echo "Running build.sh in the clean checkout..."
( cd "$WORK/repo" && bash dairy-api/build.sh ) || {
    echo "FAIL: build.sh exited non-zero in a clean checkout"; exit 1; }

CTX="$WORK/repo/dairy-api"
missing=0

# Find an interpreter that actually runs -- same reasoning as build.sh: being on
# PATH is not enough, because Windows ships a python3 App Execution Alias that
# resolves and then exits without running anything.
PYTHON=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "pass" >/dev/null 2>&1; then
        PYTHON="$cand"; break
    fi
done

require_file() {
    if [ ! -f "$CTX/$1" ]; then echo "  MISSING: dairy-api/$1"; missing=$((missing + 1)); fi
}

fail() { echo "  $1"; missing=$((missing + 1)); }

require_count() {
    # $1 glob, $2 expected count, $3 label
    n=$(find "$CTX" -path "$CTX/$1" -type f 2>/dev/null | wc -l)
    if [ "$n" -ne "$2" ]; then
        echo "  WRONG COUNT: $3 -- expected $2, found $n"; missing=$((missing + 1))
    fi
}

echo "Checking the context..."

# Classifier artifacts. The API loads 10 variants; /health reports the count,
# and the README tells a deployer to expect 10.
require_count "models/variants/*.joblib" 10 "classifier variants"
require_file "models/variants/variants_config.json"
require_file "models/config.json"

# Guidance. read_guidance serves these from the image, so a context without them
# leaves every route file unreachable through the tool -- and the router's first
# instruction is to read one before answering.
for n in 0 1 2 3 4 5; do
    if [ -z "$(find "$CTX/guidance/routes" -name "$n-*.md" -type f 2>/dev/null)" ]; then
        echo "  MISSING: dairy-api/guidance/routes/$n-*.md"; missing=$((missing + 1))
    fi
done
require_file "guidance/reference/spoilage-classification-model.md"
require_file "guidance/reference/vsl-program.md"

# The Dockerfile COPYs this unconditionally, so a context without it fails the
# image build rather than only the drift check.
require_file "build_info.json"

# R model code.
require_file "milk-spoilage-model/config.R"
require_file "milk-spoilage-model/run_model.R"
for d in pathways scenarios utils; do
    if [ ! -d "$CTX/milk-spoilage-model/$d" ]; then
        echo "  MISSING: dairy-api/milk-spoilage-model/$d/"; missing=$((missing + 1))
    fi
done

# Baseline temperature profiles and the container pools.
for f in baseline_consumer baseline_facility_storage baseline_retail \
         baseline_transport_to_retail high_growth_containers \
         medium_growth_containers ppc_growth_params ppc_st_frequency; do
    require_file "milk-spoilage-model/input_data/$f.csv"
done

# S1-S4 disruption profiles. run_simulation.R:52-64 names these paths, so a
# context without them yields a Space where every S1-S4 preset fails at runtime.
for f in scenario_s1_storage_cooling_disruption scenario_s2_delivery_delay \
         scenario_s3_trunk_opening scenario_s4_delivery_cooling_disruption; do
    require_file "milk-spoilage-model/input_data/$f.csv"
done

if [ -z "$PYTHON" ]; then
    echo "  NOTE: no working python found; skipping the pin and resolver checks."
else

# The classifier download must be reproducible. `main` is a moving pointer: the
# model repo has already advanced 14 times, and the same build.sh against the
# same repo id would have pulled 0, 1 or 12 model files depending on the day.
# A retrain upstream would silently hand this image joblibs pickled by a newer
# scikit-learn than requirements.txt installs.
# Every value read out of a file gets CR-stripped. The clean checkout is built by
# taring the working tree, so on Windows these files arrive with CRLF endings --
# and MSYS sed strips the CR transparently while GNU sed does not. Without this,
# the sklearn comparison below passed on Windows and reported a false
# "PIN MISMATCH: ... 1.8.0, ... 1.8.0" on Linux, CI and the Space builder, which
# is the wrong way round for a guard: it would have been loosened, not believed.
# Capture whatever the assignment holds, not just its leading hex run. Matching
# [0-9a-f]* meant a branch name like "main" produced an empty capture and the
# failure read "found '<unset>'", which is not what is wrong with it.
rev=$(sed -n 's/^HF_MODEL_REVISION=["'"'"']\{0,1\}\([^"'"'"' ]*\).*/\1/p' "$CTX/build.sh" | head -1 | tr -d '\r')
case "$rev" in
    ????????????????????????????????????????)
        echo "  classifier revision pinned: $rev" ;;
    *)  fail "NOT PINNED: build.sh must set HF_MODEL_REVISION to a 40-char commit SHA, found '${rev:-<unset>}'" ;;
esac

# The MCP SDK must carry an upper bound below 2. A lower bound alone is not
# enough: `mcp>=1.26` resolved to 2.0.0 on a clean install, 2.0 moved FastMCP to
# MCPServer under a different module, and the image died at import while every
# test on a machine already holding 1.26.0 passed. pip re-resolves only on a
# fresh install, so a development machine cannot see it and this is the cheapest
# place that can.
#
# The upper bound is what is checked, rather than an exact pin. `<2` is the
# SDK's own published instruction for a package in this position, and it is the
# half that closes the hazard -- while `==` would also close the route to a 1.x
# security patch, which the v1.x line still receives. An exact pin is accepted
# too: it satisfies the hazard, and forbidding it would fail a deliberate
# temporary pin during a bisect. See ADR 018.
# The specifier is RESOLVED rather than pattern-matched. A substring test for
# "<2" passes `<20`, `<2.1` and `<2.0.1`, and every one of those installs 2.0.0
# -- so the guard would have approved exactly the drift it exists to stop. The
# question is not what the string looks like, it is which versions the
# specifier admits, and only a resolver answers that.
mcp_pin=$(sed -n 's/^mcp\([<>=!][^ #]*\).*/\1/p' "$CTX/requirements.txt" | head -1 | tr -d '\r')
mcp_verdict=$("$PYTHON" -c "
import sys
try:
    from packaging.specifiers import SpecifierSet
except ImportError:
    print('NOPKG'); sys.exit()
spec = sys.argv[1]
if not spec:
    print('UNSET'); sys.exit()
try:
    admitted = SpecifierSet(spec)
except Exception:
    print('UNPARSEABLE'); sys.exit()
# Any release without mcp.server.fastmcp. 2.0.0 is the one that actually broke
# the image; the rest guard against a cap that only excludes that single
# release while admitting its successors.
bad = [v for v in ('2.0.0', '2.0.1', '2.1.0', '3.0.0') if admitted.contains(v)]
print('ADMITS ' + ','.join(bad) if bad else 'OK')
" "$mcp_pin" 2>/dev/null | tr -d '\r')
case "$mcp_verdict" in
    OK)     echo "  mcp cannot resolve to 2.x or later: mcp$mcp_pin" ;;
    NOPKG)  echo "  mcp bound not resolved (packaging unavailable): mcp$mcp_pin" ;;
    UNSET)  fail "UNBOUNDED: requirements.txt states no version for mcp. It must exclude 2.x (e.g. 'mcp>=1.26,<2')" ;;
    ADMITS*)
        fail "UNBOUNDED: 'mcp$mcp_pin' still installs ${mcp_verdict#ADMITS }, which has no mcp.server.fastmcp. Cap it below 2.0 (e.g. 'mcp>=1.26,<2')" ;;
    *)      fail "UNREADABLE: cannot parse the mcp requirement 'mcp${mcp_pin:-<unset>}'" ;;
esac

# The two pins have to move together. This reads the scikit-learn version out of
# the artifact build.sh actually downloaded and compares it to the version
# requirements.txt installs, so repinning either one alone goes red here.
pinned_sklearn=$(sed -n 's/^scikit-learn==\([0-9][^ #]*\).*/\1/p' "$CTX/requirements.txt" | head -1 | tr -d '\r')
pickled_sklearn=$("$PYTHON" -c "
import re, sys
b = open(sys.argv[1], 'rb').read(4096)
m = re.search(rb'_sklearn_version.{0,12}?(\d+\.\d+\.\d+)', b, re.S)
print(m.group(1).decode() if m else '')
" "$CTX/models/variants/baseline.joblib" 2>/dev/null | tr -d '\r')
if [ -z "$pickled_sklearn" ]; then
    fail "UNREADABLE: no _sklearn_version in models/variants/baseline.joblib"
elif [ "$pinned_sklearn" != "$pickled_sklearn" ]; then
    fail "PIN MISMATCH: artifacts pickled by sklearn $pickled_sklearn, requirements.txt installs $pinned_sklearn"
else
    echo "  sklearn pin agrees with the artifacts: $pinned_sklearn"
fi

# Every third-party module the deploy scripts import must be declared somewhere.
# They are not installed into the image and never run there, so their
# dependencies live in their own requirements file -- but undeclared is
# undeclared, and a clean environment then fails on `--dry-run`, or on the
# post-deploy drift check, before either can do anything.
# Capture the exit status separately rather than piping straight into `tr`.
# Piped, the status came from `tr` -- which succeeds whatever Python did -- so a
# crashed audit produced an empty string and was read as "nothing undeclared".
# That is the same defect this script exists to catch, in the checker itself.
audit_out=$("$PYTHON" -c "
import ast, importlib.util, os, re, sys, sysconfig
from pathlib import Path

def is_stdlib(name):
    # sys.stdlib_module_names is 3.10+. Fall back to asking where the module
    # lives, so this audit runs on older interpreters instead of dying and
    # being mistaken for a pass.
    names = getattr(sys, 'stdlib_module_names', None)
    if names is not None:
        return name in names
    if name in sys.builtin_module_names:
        return True
    try:
        spec = importlib.util.find_spec(name)
    except (ImportError, ValueError):
        return False
    origin = getattr(spec, 'origin', None) or ''
    if not origin:
        return False

    # Both sides are normalised before comparing, for two independent reasons.
    # Case: sysconfig reports <prefix>/Lib on Windows while module origins say
    # <prefix>/lib, so a raw startswith matched nothing and called the whole
    # standard library third-party. Symlinks: a venv or pyenv prefix may resolve
    # elsewhere.
    def norm(p):
        return os.path.normcase(os.path.realpath(p))

    # site-packages sits UNDER stdlib on common layouts -- pyenv, and Windows,
    # where stdlib is <prefix>/Lib and purelib is <prefix>/Lib/site-packages.
    # A bare stdlib prefix test therefore calls every installed third-party
    # module stdlib, and the audit would pass for a package merely installed
    # here while undeclared for a clean deployment. Package directories are
    # checked first, and win.
    paths = sysconfig.get_paths()
    pkg_dirs = [paths.get('purelib'), paths.get('platlib')]
    try:
        import site
        pkg_dirs += list(site.getsitepackages()) + [site.getusersitepackages()]
    except Exception:
        pass

    origin_n = norm(origin)
    stdlib_n = norm(paths['stdlib'])
    # site.getsitepackages() returns the interpreter prefix itself on Windows,
    # which is an ancestor of the standard library -- so an unfiltered list made
    # every stdlib module look like a package and inverted the whole test. Keep
    # only directories that are not ancestors of stdlib.
    pkg_n = [norm(d) for d in pkg_dirs if d]
    pkg_n = [d for d in pkg_n if not stdlib_n.startswith(d)]
    if any(origin_n.startswith(d) for d in pkg_n):
        return False
    return origin_n.startswith(stdlib_n)

ctx = Path(sys.argv[1])
mods = set()
for script in ('deploy_space.py', 'check_deployment.py'):
    for n in ast.walk(ast.parse((ctx / script).read_text())):
        if isinstance(n, ast.Import):
            mods |= {a.name.split('.')[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom) and not n.level and n.module:
            mods.add(n.module.split('.')[0])

# A module that ships in the context beside the script is not a dependency to
# declare. Without this, payload.py and build_info.py -- both imported by the
# deploy scripts and both sitting right there -- read as undeclared third-party
# packages and failed the audit.
mods = {m for m in mods
        if not (ctx / f'{m}.py').is_file() and not (ctx / m / '__init__.py').is_file()}

declared = set()
for req in ctx.glob('requirements*.txt'):
    for line in req.read_text().splitlines():
        line = line.split('#')[0].strip()
        if line and not line.startswith('-'):
            declared.add(re.split(r'[<>=!\[;]', line)[0].strip().replace('-', '_').lower())
print(' '.join(sorted(m for m in mods
                      if not is_stdlib(m)
                      and m.replace('-', '_').lower() not in declared)))
" "$CTX" 2>&1)
audit_status=$?
if [ "$audit_status" -ne 0 ]; then
    fail "AUDIT FAILED: the dependency check could not run (exit $audit_status): $(printf '%s' "$audit_out" | tail -1)"
else
    undeclared=$(printf '%s' "$audit_out" | tr -d '\r')
    if [ -n "$undeclared" ]; then
        fail "UNDECLARED: the deploy scripts import $undeclared, in no dairy-api/requirements*.txt"
    else
        echo "  deploy script imports are all declared"
    fi
fi

# The documented non-Docker launch -- `cd dairy-api && uvicorn app:app` -- has to
# find the artifacts build.sh just assembled. The resolver used to check only the
# untracked MilkSpoilageClassifier clone and the in-image /app path, so a clean
# checkout raised FileNotFoundError at import even with the context complete.
# Stub the runtime packages before importing. This script never installs
# requirements.txt, so on a clean build host `import joblib` fails and the check
# used to downgrade itself to a NOTE while the script still printed PASS -- the
# advertised regression test silently not running in its most common case.
#
# _resolve_variants_dir is a staticmethod that touches only pathlib, so stubbing
# the module-level joblib and numpy imports exercises the real resolver rather
# than a reimplementation of it. Anything else failing to import is a genuine
# failure and is reported as one.
probe=$( cd "$CTX" && "$PYTHON" -c "
import sys, types
from pathlib import Path
for name in ('joblib', 'numpy'):
    sys.modules.setdefault(name, types.ModuleType(name))
from services.classifier import ClassifierService
got = Path(ClassifierService._resolve_variants_dir()).resolve()
want = (Path.cwd() / 'models' / 'variants').resolve()
n = len(list(got.glob('*.joblib')))
print(f'{got} ({n} variants), wanted {want}')
sys.exit(0 if got == want and n >= 1 else 3)
" 2>&1 )
case "$?" in
    0) echo "  non-Docker resolver finds the build context" ;;
    3) fail "WRONG DIR: the resolver returned $probe" ;;
    *) fail "RESOLVER FAILED: $(printf '%s' "$probe" | tail -1)" ;;
esac

fi

if [ "$missing" -gt 0 ]; then
    echo
    echo "FAIL: $missing problem(s) in a clean-checkout build context."
    exit 1
fi

echo "PASS: the build context is complete from a clean checkout."
