# Native runtime laws

From this directory, run the repository's built `cljw -M:verify` for the
library integration proof, or `cljw -M:laws` for runtime regressions.
Both commands use the source pins in `deps.edn`.

`laws` runs 2100 generated cases with recorded seeds, three reviewed JVM
goldens, and six mutation witnesses. Properties cover split `apply` arguments,
concatenation order, subvector partition conservation, fractional repeat
counts and literal replacement. Mutation witnesses change the production
`subvec`, `split-lines` and `replace` Vars, then restore them in `finally`.
Run this command serially: Var root mutations affect the process.

The EDN snapshots were derived from Clojure 1.12.4 after checking behavior.
Review changes against that oracle; hive-test can create missing snapshots,
so a first-run pass alone is not evidence of correctness. To replay a property
with another seed, call its test.check function, for example
`(laws/concat-preserves-order 300 :seed 20260910)`.

These are targeted witnesses, not a source mutation score. Broader Zig source
mutation campaigns remain on demand through `scripts/mutation/run.sh`, with
`--build-args "-Dwasm -Doptimize=ReleaseSafe"` and a green baseline.
