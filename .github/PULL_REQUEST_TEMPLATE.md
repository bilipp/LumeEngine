<!--
Thanks for contributing to LumeEngine! Please read CONTRIBUTING.md if you haven't yet.
Keep PRs focused and single-purpose. Fill out the sections below.
-->

## Summary

<!-- What does this PR do, and why? For playback fixes, say what the user saw. -->

Closes #

## Type of change

- [ ] `fix` — bug fix
- [ ] `feat` — new capability
- [ ] `perf` — performance improvement
- [ ] `refactor` — neither fixes a bug nor adds a feature
- [ ] `docs` — documentation only
- [ ] `test` — adding or fixing tests
- [ ] `build` / `chore` — build pipeline, tooling, or maintenance

## Invariants

<!--
Which of the PLAN.md §3-§4 invariants does this touch, and why is it still within them?
Write "none — no data-plane changes" if that's the case.
-->

- [ ] No blocking FFmpeg call was added to an actor, and no stage bypasses `Channel`.
- [ ] No rebuild-in-place: a new URL is still a new session object.
- [ ] Raw container timestamps still stop at `TimestampUnwrapper`.
- [ ] A/V sync is still owned by `AVSampleBufferRenderSynchronizer` (no new heuristics or clocks).
- [ ] No force unwraps, `as!`, `fatalError`, or `assertionFailure` in engine paths; failures are typed.
- [ ] No new global mutable state; configuration still flows through `PlayerConfiguration`.
- [ ] No control flow derived from `av_log` strings.

## Verification

- [ ] `swift build` is warning-free.
- [ ] `swift test` is green (`N tests in M suites passed` — paste the line):

```
```

- [ ] I added or updated tests for this change. Work in `Demux/`, `Decode/`, `Time/`, or
      `Concurrency/` is expected to come with tests.
- [ ] New media fixtures (if any) were added to `generate-fixtures.sh` — no binary media committed.

## Platforms verified

- [ ] macOS
- [ ] iOS / iPadOS
- [ ] tvOS
- [ ] visionOS

## Real-world content

<!--
For playback fixes: what content did you reproduce the bug on, and what fixed it?
Describe properties only — container, codecs, live/VOD, bitrate. NEVER paste stream URLs
or provider credentials.
-->
