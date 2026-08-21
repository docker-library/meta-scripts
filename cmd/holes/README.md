# cmd/holes

`builds.json` is regenerated from scratch on every meta run.  A **hole** is any `(tag, arch)` pair that appears in `sources.json` but has no currently-resolved build in `builds.json`.  This happens in two distinct ways:

- **`resolved: null`** -- the entry exists (parents are all resolved, buildId is computed) but the staging image hasn't been built yet.
- **Entirely absent** -- `cmd/builds` emitted nothing for this `(sourceId, arch)` because a DOI parent's staging image is itself unresolved (`close(outChan)`).  The entry cannot appear in `builds.json` at all until the parent resolves.

`builds.json` cannot be used alone to detect entirely-absent holes; `sources.json` is required as the authoritative list of what *should* exist.

## Why holes matter

`library/IMAGE:TAG` is a single atomic OCI index listing all arches.  Pushing any update to it requires supplying descriptors for *every* expected arch -- you cannot leave one arch out without dropping it from the index entirely.  Meanwhile arches build at very different rates (hours for amd64, days for riscv64), so "wait for all arches before publishing" is not viable.  Holes must be filled with the most recent previously-resolved content for each `(tag, arch)` while the new build is in flight.

## Key constraints on the search key

Holes are independent per `(tag, arch)` -- not per `(sourceId, arch)`.  The reasons:

- **`sourceId` is not stable across re-adds.**  A tag removed from the library and re-added later may have a new sourceId (changed Dockerfile), breaking any lookup keyed on sourceId.  The tag name is what users pull; it is the right identity.
- **Each tag is a distinct semantic identity.**  `"golang:1.22"` and `"golang:1.22.6"` share a builds.json entry when both point at the same build, but they must be looked up independently: `"golang:1.22.6"` should never serve a fallback from `"golang:1.22.5"`, even though `"golang:1.22"` should.

Tags come from `source.arches[arch].tags`, not `archTags` -- `archTags` may be empty in non-DOI repos (e.g. `debuerreotype/debuerreotype:latest` rather than `amd64/debian:bookworm`).

## Known imprecision: multi-variant arches

For architectures with multiple OS-version variants under the same tag (e.g. `windows-amd64` with ltsc2019 and ltsc2022 both contributing to `"docker:24"`), `(tag, arch)` conflates all variants.  There is no clean way to track which specific variant is the hole without keying by sourceId -- which breaks re-added tags.  The fallback found in history may correspond to the wrong OS version.  This is accepted imprecision.

## Git history search

The git history of the meta repo contains every prior `builds.json` state.  Walking it backward is the only source of fallback data that does not require live registry queries (which are expensive enough that put-shared runs only every ~3 hours).  The walk must be a single linear backward pass over *all* holes simultaneously -- exponential or binary search is not safe because a tag can be added, fully built, *and* removed within a gap of skipped commits, leaving no evidence on either side of the jump.

## Performance

Blob enumeration uses `git log --raw` (a single native-git command) rather than go-git's commit-graph traversal, which decompresses every commit and tree object in-process and is substantially slower.

Blobs are parsed in parallel (`runtime.NumCPU()` workers, each with its own `git cat-file --batch` subprocess to avoid go-git's internal pack-file mutex).  A coordinator goroutine cancels the scan the moment every initially-unfilled hole has been filled, so recently-built tags cost only a few blobs' worth of work.

An optional third argument `prev-holes.json` pre-fills holes from the previous run's output before touching git history.  The previous `holes.json` is a valid cache because any `(tag, arch)` that was a hole on the prior run and is still a hole now can reuse the same fallback OCI index -- and as holes get resolved during builds they disappear from the current holes set (resolved in `builds.json`) so the cache never returns data for a hole that no longer exists.  On a warm run (most holes already in the cache) the git history search only covers newly-appeared holes, which are typically a small fraction of the total.  Typical invocation:

```console
$ holes sources.json builds.json holes.json > holes-new.json && mv holes-new.json holes.json
```

Setting `$HOLES_SINCE` to any expression `git log --since` understands (eg `2.weeks`, `30.days`, `2024-01-01`) limits the history search to that window.  Holes still unfilled after the window are left empty (library deploy skips them).  This trades correctness -- a tag last resolved before the cutoff gets no fallback -- for a bounded worst-case runtime.  It is most useful when brand-new tags (which can never be filled from history) regularly appear in large batches and would otherwise force a full scan by preventing the all-holes-filled early exit.  It composes well with the cache: the cache handles previously-known holes instantly, and `$HOLES_SINCE` bounds the search for any new ones.
