# Contributing

This guide is for someone who wants to build the package, run its tests and gates, and open a pull request. It covers
the tools, the build step by step, the gates every change must pass, and how a pull request is released. The
[design document](design.md) describes what is underneath.

## 1. Tools

| Tool | Needed for | Version |
|---|---|---|
| Julia | Everything | 1.10 (the LTS) or later; CI tests the LTS and the latest |
| Git | The repository and the test data | Any recent version |
| Python 3 | The check of the Unicode tables against the Rust crate's | 3.10 or later |
| Node.js | The test data for other versions of Unicode and for ECMAScript 2020, and the V8 rows of the harness | 24 (the V8 it carries is the oracle) |
| PowerShell 7 | The release scripts (`tools/release`) | 7.4 or later |

[juliaup](https://github.com/JuliaLang/juliaup) installs Julia on every platform (`winget install julia -s msstore` on
Windows, `curl -fsSL https://install.julialang.org | sh` on Linux and macOS) and keeps the LTS beside the latest
(`juliaup add lts`). Git, Python 3, Node.js 24 and PowerShell come from winget, the distribution or Homebrew.

## 2. Getting the sources

```
git clone https://github.com/corvus-dotnet/corvus-regex-ecma262-jl.git
git clone https://github.com/corvus-dotnet/ecma262-regex-test-data.git   # beside it: the test data
git clone https://github.com/corvus-dotnet/corvus-regex-ecma262-rs.git   # beside it: for the table check
cd corvus-regex-ecma262-jl
```

The test data is the oracle for the engine (design, section 6). It is not vendored; the commands below assume it at
`../ecma262-regex-test-data`.

## 3. Building and testing, step by step

Every command runs from the repository root.

1. **The tests.** `julia --project=. -e 'using Pkg; Pkg.test()'` runs the tests, the allocation test and the
   getting-started page's examples; again with `CORVUS_REGEX_MEMO_FROM_THE_START=1`, which takes the memo of failed
   places into use from the first step. Run them on the LTS too (`julia +lts`).
2. **The API reference.** After a change to a docstring, run `julia --project=. tools/docs/gen-api.jl`;
   `julia --project=. tools/docs/gen-api.jl --check` must pass.
3. **The stack probe.** `julia --project=. tools/stackprobe/run.jl` asks the deep, wide and long patterns; none may
   overflow.
4. **The test data.** `julia --project=. -t 4 tools/dataset/run.jl ../ecma262-regex-test-data/data wrong-cases.tsv` must
   report 0 wrong, 0 refused and 0 at a limit, and again with `CORVUS_REGEX_MEMO_FROM_THE_START=1`. For the other
   versions of Unicode and for ECMAScript 2020, write the data with its own scripts and run it with the package set to
   match:

   ```
   node ../ecma262-regex-test-data/unicode.js apply 13.0 /tmp/u13 ../ecma262-regex-test-data/data
   julia --project=. -t 4 tools/dataset/run.jl /tmp/u13 wrong-u13.tsv --unicode 13
   node ../ecma262-regex-test-data/edition.js apply /tmp/es2020 "" ../ecma262-regex-test-data/data
   julia --project=. -t 4 tools/dataset/run.jl /tmp/es2020 wrong-es2020.tsv --edition es2020
   ```

## 4. The Unicode tables

The tables of each version of Unicode (`src/ucd/tables<major>_gen.jl`, `strings<major>_gen.jl`) and the property names
of ECMAScript 2020 (`src/es2020_gen.jl`) are written from the Rust crate's, so that every engine carries the same
tables. After the crate's tables change:

```
src=../corvus-regex-ecma262-rs/corvus-regex-ecma262/src
for major in 13 17 18; do
  python3 tools/unicode/gen_tables.py $src/tables$major.rs
  python3 tools/unicode/gen_strings.py $src/strings$major.rs
done
python3 tools/unicode/gen_es2020.py $src/es2020.rs
```

With `--check`, each script fails when what is checked in differs, as CI runs them.

## 5. Benchmarks

`tools/benchmarks/run.sh <workloads.json> <texts directory> <out.json>` runs this package, Julia's `Regex` and V8 over
the Industry workloads; the script lists what it needs and its settings. The published figures are on
[the benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), which runs this repository's harness
image each night beside every other engine; a run on another machine is comparable with itself, never with the page.

## 6. What a pull request needs

- **The gates of section 3** passing on the change as pushed, on the LTS and the latest Julia.
- **The case in the test data first** for a change to the engine's semantics: add the pattern to the data repository's
  family it belongs to, regenerate with its `generate.js`, check with `verify.js`, and pin the new data commit in
  `ci.yml`. V8 is the oracle; a fault V8 has is marked in the data, never copied into the engine.
- **A failing test first** for a bug: the test that reproduces it, then the fix.
- **A measured run** for a change made for speed, with the rows it moved.
- **The design document kept current**, describing the package as it is.
- **Docstrings** on every public name, since the API reference is generated from them.
- **The getting-started page** kept true: its examples are run by the tests.

### Conventions

- Pure Julia with no dependencies; the vector compares are `llvmcall`, not a package.
- Nothing on the match path allocates once warm, and the allocation test holds that line.
- The code a first pattern and match need is in the precompile workload (`src/precompile.jl`).

## 7. Releases

Every pull request merged into main releases the package with the next patch version, unless it is labelled
`no_release`: `auto-release.yml` runs `tools/release` on the merge, which tags `v<version>` on a commit with the
version written into `Project.toml` (main keeps 0.0.0), and `julia-publish.yml` asks JuliaRegistrator to register that
commit in the General registry. A change to the published documents releases a patch too, since the documentation site
takes them from the latest release. A change to the benchmark harness alone is a harness release, which publishes the
harness image. A pull request that needs a minor or major version sets `nextVersion` in `.github/release.json`.

`main` is protected by a ruleset: changes arrive by pull request, and the `CI gate` and `Harness image` checks must be
green on the branch as it will merge.
