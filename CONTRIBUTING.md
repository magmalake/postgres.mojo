# Contributing

1. Fork, branch off `main`.
2. `pixi run test` on both toolchains (`pixi run -e stable test` for 1.0.0) —
   the server suite needs nothing but the conda env, it starts its own cluster.
3. `pixi run format-check` before committing.
4. If you change the public API, update `README.md` and `examples/`.
5. Open a PR. Small focused PRs over big ones.

Design questions belong on
[magmalake.org/issues/1](https://magmalake.org/issues/1), the spec this tin is
built to.
