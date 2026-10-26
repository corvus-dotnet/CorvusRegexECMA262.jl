#!/usr/bin/env bash
# Readies the harness: the package precompiled, with the workload of src/precompile.jl, so that each figure's process
# starts on compiled code. run.sh calls it, and the image (Dockerfile) calls it when it is built.
set -euo pipefail
cd "$(dirname "$0")/../.."
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); using CorvusRegexEcma262'
