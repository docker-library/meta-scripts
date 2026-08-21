package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"

	// encoding/json/v2, but not yet
	jsonv2 "github.com/go-json-experiment/json"
	"github.com/go-json-experiment/json/jsontext"

	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

// hole represents a single (tag, arch) pair with no resolved entry in the current builds.json.  Each (tag, arch) is an independent hole: "golang:1.22" on amd64 and "golang:1.22.6" on amd64 have completely different historical content and must be looked up separately.
//
// "tag" is a value from source.arches[arch].tags (e.g. "golang:1.22" or "debuerreotype/debuerreotype:latest") -- NOT the arch-prefixed archTag, which may be empty in non-DOI repos.
//
// Note: for architectures with multiple OS-version variants (e.g. windows-amd64 with ltsc2019 and ltsc2022), the (tag, arch) key conflates all variants.  We accept this imprecision; there is no clean way to track partial holes within a single (tag, arch) pair.
type hole struct {
	tag  string
	arch string
}

// tagArchKey returns the map key used in keyToHole.  A null byte is safe since neither tags nor arch names ever contain one.
func tagArchKey(tag, arch string) string {
	return tag + "\x00" + arch
}

// blobMatch is a single resolved entry found in a historical builds.json blob that matches an unfilled hole.
type blobMatch struct {
	slotIdx  int // position in newest-to-oldest order (lower = more recent)
	holeIdx  int
	resolved *ocispec.Index
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "usage: %s sources.json builds.json [prev-holes.json]\n", os.Args[0])
		os.Exit(1)
	}
	sourcesFile := os.Args[1]
	buildsFile := os.Args[2]
	prevHolesFile := ""
	if len(os.Args) >= 4 {
		prevHolesFile = os.Args[3]
	}

	// HOLES_SINCE, if set, is passed directly to "git log --since=..." to limit how far back the
	// history search reaches; accepts any expression git understands (e.g. "2.weeks", "30.days",
	// "2024-01-01"); see README for trade-offs
	holesSince := os.Getenv("HOLES_SINCE")

	// --- Step 1: parse sources.json for the full expected (sourceId, arch) set ---

	sourcesF, err := os.Open(sourcesFile)
	if err != nil {
		panic(err)
	}
	// sources.json is an object whose values each have a sourceId and an arches map; we need sourceId + arches[*].tags (archTags may be empty)
	var sources map[string]struct {
		SourceID string `json:"sourceId"`
		Arches   map[string]struct {
			Tags []string `json:"tags"`
		} `json:"arches"`
	}
	if err := json.NewDecoder(sourcesF).Decode(&sources); err != nil {
		panic(err)
	}
	sourcesF.Close()

	// --- Step 2: parse builds.json to find which (sourceId, arch) are resolved ---

	buildsF, err := os.Open(buildsFile)
	if err != nil {
		panic(err)
	}
	// we only need sourceId, arch, and whether resolved is non-null
	var builds map[string]struct {
		Build struct {
			SourceID string         `json:"sourceId"`
			Arch     string         `json:"arch"`
			Resolved *ocispec.Index `json:"resolved"`
		} `json:"build"`
	}
	if err := json.NewDecoder(buildsF).Decode(&builds); err != nil {
		panic(err)
	}
	buildsF.Close()

	resolvedSet := make(map[string]bool, len(builds)) // key: sourceId+"-"+arch
	for _, entry := range builds {
		if entry.Build.Resolved != nil {
			resolvedSet[entry.Build.SourceID+"-"+entry.Build.Arch] = true
		}
	}

	// --- Step 3: compute holes ---
	// a hole is any (tag, arch) from sources.json where the backing (sourceId, arch) has no resolved entry in builds.json -- whether entirely absent (unresolved parent chain) or present with resolved == null
	// each (tag, arch) is independent: "golang:1.22" may have a historical fallback while "golang:1.22.6" does not

	var holes []hole
	// keyToHoles maps tagArchKey(tag, arch) to the list of indices in holes that share that (tag, arch).  Normally exactly one entry; multiple entries arise when several sources share the same (tag, arch) -- e.g. windows-amd64 with ltsc2019 AND ltsc2022 both contributing to "docker:24".
	//
	// Known, accepted imprecision: because we can only search git history by (tag, arch), we cannot tell which specific OS-version variant is the hole, so we may fill slots with fallbacks for the wrong variant.
	keyToHoles := map[string][]int{}

	for _, src := range sources {
		for arch, archData := range src.Arches {
			if resolvedSet[src.SourceID+"-"+arch] {
				continue
			}
			for _, tag := range archData.Tags {
				k := tagArchKey(tag, arch)
				idx := len(holes)
				holes = append(holes, hole{tag: tag, arch: arch})
				keyToHoles[k] = append(keyToHoles[k], idx)
			}
		}
	}

	if len(holes) == 0 {
		fmt.Println("{}")
		return
	}
	fmt.Fprintf(os.Stderr, "searching git history for %d hole(s)\n", len(holes))

	// results[i] holds the best resolved OCI index found for holes[i]; nil means unfilled.
	// bestSlot[i] tracks the slot index (lower = more recent) of the result in holes[i]:
	//   math.MaxInt   = no result yet (unfilled); counted in initialRemaining; git will search for it
	//   math.MaxInt-1 = filled from prev-holes.json cache; not counted; git can still improve it
	//   math.MaxInt-2 = cache recorded null (previously searched, not found); not counted; git can
	//                   still passively improve it if a match is encountered while scanning for others
	//   0..N          = filled from git history blob at that slot index
	results := make([]*ocispec.Index, len(holes))
	bestSlot := make([]int, len(holes))
	for i := range bestSlot {
		bestSlot[i] = math.MaxInt
	}

	// --- Step 3.5: pre-fill holes from previous holes.json (cache) ---
	// The previous run's holes.json is a valid cache: any (tag, arch) that was a hole then
	// and is still a hole now can reuse the same fallback resolved index without re-scanning
	// git history.  Holes that have since been filled (resolved in builds.json) are no longer
	// in the current holes set, so the cache never returns data for a hole that no longer exists.
	//
	// For the windows multi-variant case where multiple holes share the same (tag, arch) key,
	// cached entries are distributed across the current holes for that key in order.

	if prevHolesFile != "" {
		var prevHoles map[string]map[string][]*ocispec.Index
		f, err := os.Open(prevHolesFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: could not open %s: %v\n", prevHolesFile, err)
		} else {
			if err := json.NewDecoder(f).Decode(&prevHoles); err != nil {
				fmt.Fprintf(os.Stderr, "warning: ignoring malformed %s: %v\n", prevHolesFile, err)
			}
			f.Close()
		}

		cacheHits := 0
		cacheNulls := 0
		for tag, arches := range prevHoles {
			for arch, cachedIndices := range arches {
				holeIndices := keyToHoles[tagArchKey(tag, arch)]
				if cachedIndices == nil {
					// null in previous holes.json: was searched and not found; skip git search
					// (git can still passively improve these if a match is encountered for other holes)
					for _, holeIdx := range holeIndices {
						bestSlot[holeIdx] = math.MaxInt - 2
						cacheNulls++
					}
					continue
				}
				for j, holeIdx := range holeIndices {
					if j >= len(cachedIndices) || cachedIndices[j] == nil {
						break
					}
					results[holeIdx] = cachedIndices[j]
					bestSlot[holeIdx] = math.MaxInt - 1 // filled from cache; git can improve
					cacheHits++
				}
			}
		}
		if cacheHits > 0 || cacheNulls > 0 {
			fmt.Fprintf(os.Stderr, "pre-filled %d hole(s) from %s (%d unfillable skipped)\n", cacheHits, prevHolesFile, cacheNulls)
		}
	}

	// count holes with no cache result at all (math.MaxInt); math.MaxInt-1 (filled) and
	// math.MaxInt-2 (null/unfillable) are both excluded -- neither needs a git search
	initialRemaining := 0
	for _, s := range bestSlot {
		if s == math.MaxInt {
			initialRemaining++
		}
	}

	if initialRemaining == 0 {
		fmt.Fprintf(os.Stderr, "all holes accounted for by cache; skipping git history search\n")
	} else {
		// --- Step 4: locate the git repo that contains builds.json ---
		// Use native git rather than go-git: "git rev-parse --show-toplevel" is fast and handles
		// DetectDotGit automatically.

		absBuilds, err := filepath.Abs(buildsFile)
		if err != nil {
			panic(err)
		}
		rootCmd := exec.Command("git", "rev-parse", "--show-toplevel")
		rootCmd.Dir = filepath.Dir(absBuilds)
		rootOut, err := rootCmd.Output()
		if err != nil {
			panic(fmt.Errorf("locating git repo root: %w", err))
		}
		repoRoot := strings.TrimRight(string(rootOut), "\r\n")
		relBuilds, err := filepath.Rel(repoRoot, absBuilds)
		if err != nil {
			panic(err)
		}

		// --- Step 5a: collect ordered unique blob hashes via git log ---
		// "git log --raw" emits one diff-stat line per commit showing old and new blob hashes;
		// we extract the new blob hash for each version of builds.json in newest-to-oldest order.
		// This is a single fast git command rather than go-git decompressing every commit+tree object.

		type blobSlot struct {
			idx      int
			blobHash string // 40-char hex
		}

		logArgs := []string{"log", "--raw", "--no-abbrev", "--format="}
		if holesSince != "" {
			logArgs = append(logArgs, "--since="+holesSince)
		}
		logArgs = append(logArgs, "--", relBuilds)
		logCmd := exec.Command("git", logArgs...)
		logCmd.Dir = repoRoot
		logOut, err := logCmd.StdoutPipe()
		if err != nil {
			panic(err)
		}
		if err := logCmd.Start(); err != nil {
			panic(err)
		}

		var slots []blobSlot
		seenBlob := make(map[string]bool)

		logScanner := bufio.NewScanner(logOut)
		for logScanner.Scan() {
			line := logScanner.Text()
			if !strings.HasPrefix(line, ":") {
				continue // blank lines and non-diff lines
			}
			parts := strings.Fields(line)
			if len(parts) < 4 {
				continue
			}
			newBlob := parts[3]
			if newBlob == "0000000000000000000000000000000000000000" {
				continue // deletion: builds.json was removed in this commit
			}
			if seenBlob[newBlob] {
				continue // identical blob already queued
			}
			seenBlob[newBlob] = true
			slots = append(slots, blobSlot{len(slots), newBlob})
		}
		if err := logScanner.Err(); err != nil {
			panic(err)
		}
		if err := logCmd.Wait(); err != nil {
			panic(fmt.Errorf("git log: %w", err))
		}

		if holesSince != "" {
			fmt.Fprintf(os.Stderr, "note: history search limited to builds since %q ($HOLES_SINCE); %d hole(s) may go unfilled\n", holesSince, initialRemaining)
		}
		fmt.Fprintf(os.Stderr, "scanning %d unique blob version(s) of %s\n", len(slots), relBuilds)

		// --- Step 5b: parse blobs in parallel with early exit ---
		// Each worker drives its own "git cat-file --batch" process (no go-git internal mutex).
		// A coordinator goroutine receives all matches and cancels the context once every
		// initially-unfilled hole has been filled; the feeder goroutine stops immediately.
		// Cache-filled holes (bestSlot == math.MaxInt-1) are not counted in initialRemaining
		// but can still be improved to a more recent git entry for free.

		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		matches := make(chan blobMatch, 256)

		// coordinator: single goroutine owns bestSlot/results (no locks needed), cancels when done
		var coordDone sync.WaitGroup
		coordDone.Add(1)
		go func() {
			defer coordDone.Done()
			remaining := initialRemaining
			for m := range matches {
				if m.slotIdx < bestSlot[m.holeIdx] {
					if bestSlot[m.holeIdx] == math.MaxInt {
						remaining--
						if remaining == 0 {
							cancel() // all initially-unfilled holes filled; stop feeder and workers
						}
					}
					bestSlot[m.holeIdx] = m.slotIdx
					results[m.holeIdx] = m.resolved
				}
			}
		}()

		numWorkers := runtime.NumCPU()
		if numWorkers > len(slots) {
			numWorkers = len(slots)
		}

		jobs := make(chan blobSlot, numWorkers)

		// feeder: stops the moment ctx is cancelled (all initially-unfilled holes filled)
		go func() {
			defer close(jobs)
			for _, slot := range slots {
				select {
				case jobs <- slot:
				case <-ctx.Done():
					return
				}
			}
		}()

		var wg sync.WaitGroup
		for w := range numWorkers {
			wg.Add(1)
			go func(workerID int) {
				defer wg.Done()

				cmd := exec.Command("git", "cat-file", "--batch")
				cmd.Dir = repoRoot
				catIn, err := cmd.StdinPipe()
				if err != nil {
					fmt.Fprintf(os.Stderr, "warning: worker %d: creating git cat-file stdin pipe: %v\n", workerID, err)
					return
				}
				catOut, err := cmd.StdoutPipe()
				if err != nil {
					fmt.Fprintf(os.Stderr, "warning: worker %d: creating git cat-file stdout pipe: %v\n", workerID, err)
					return
				}
				if err := cmd.Start(); err != nil {
					fmt.Fprintf(os.Stderr, "warning: worker %d: starting git cat-file: %v\n", workerID, err)
					return
				}

				catBuf := bufio.NewReader(catOut)

			loop:
				for slot := range jobs {
					if ctx.Err() != nil {
						break loop // all initially-unfilled holes filled; stop requesting new blobs
					}

					if _, err := fmt.Fprintf(catIn, "%s\n", slot.blobHash); err != nil {
						fmt.Fprintf(os.Stderr, "warning: worker %d: writing to git cat-file (blob %s): %v\n", workerID, slot.blobHash, err)
						continue
					}

					// response header: "<hash> blob <size>\n" or "<hash> missing\n"
					line, err := catBuf.ReadString('\n')
					if err != nil {
						fmt.Fprintf(os.Stderr, "warning: worker %d: reading git cat-file header (blob %s): %v\n", workerID, slot.blobHash, err)
						continue
					}
					parts := strings.Fields(line)
					if len(parts) < 3 || parts[1] != "blob" {
						fmt.Fprintf(os.Stderr, "warning: worker %d: unexpected git cat-file response %q for blob %s\n", workerID, strings.TrimRight(line, "\n"), slot.blobHash)
						continue
					}
					size, err := strconv.ParseInt(parts[2], 10, 64)
					if err != nil {
						fmt.Fprintf(os.Stderr, "warning: worker %d: bad size %q for blob %s: %v\n", workerID, parts[2], slot.blobHash, err)
						continue
					}

					// LimitedReader prevents the decoder from reading into the next blob's header
					lr := &io.LimitedReader{R: catBuf, N: size}
					if err := searchBlob(ctx, lr, keyToHoles, slot.idx, matches); err != nil {
						fmt.Fprintf(os.Stderr, "warning: worker %d: skipping blob %s: %v\n", workerID, slot.blobHash, err)
					}
					// drain any unread bytes (after a parse error or ctx-triggered early return)
					if _, err := io.Copy(io.Discard, lr); err != nil {
						fmt.Fprintf(os.Stderr, "warning: worker %d: draining blob %s: %v\n", workerID, slot.blobHash, err)
					}
					if _, err := catBuf.ReadByte(); err != nil { // trailing LF after blob content
						fmt.Fprintf(os.Stderr, "warning: worker %d: reading trailing newline for blob %s: %v\n", workerID, slot.blobHash, err)
					}
				}

				go io.Copy(io.Discard, catOut) // let git flush and exit without blocking on a full pipe
				catIn.Close()
				cmd.Wait()
			}(w)
		}

		wg.Wait()
		close(matches)   // signal coordinator that no more matches are coming
		coordDone.Wait() // drain any in-flight matches before reading results

		unfilledCount := 0
		for _, s := range bestSlot {
			if s == math.MaxInt {
				unfilledCount++
			}
		}
		if unfilledCount > 0 {
			fmt.Fprintf(os.Stderr, "warning: %d hole(s) could not be filled from git history\n", unfilledCount)
		}
	}

	// --- Step 6: emit holes.json ---

	// holes.json: { tag -> { arch -> [ resolved OCI index, ... ] } }
	// O(1) lookup by (tag, arch); the list normally has one entry; it has more when multiple OS-version variants (e.g. Windows) share the same (tag, arch).
	// Unfillable holes (no resolved entry anywhere in history) are recorded as null rather than
	// omitted: this lets the next run recognise them as "previously searched, still not found"
	// and skip the git search for them, rather than scanning history again to reach the same result.
	output := map[string]map[string][]*ocispec.Index{}
	for i, h := range holes {
		if output[h.tag] == nil {
			output[h.tag] = map[string][]*ocispec.Index{}
		}
		if results[i] != nil {
			output[h.tag][h.arch] = append(output[h.tag][h.arch], results[i])
		} else if _, exists := output[h.tag][h.arch]; !exists {
			output[h.tag][h.arch] = nil // null sentinel: searched, not found
		}
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "\t")
	if err := enc.Encode(output); err != nil {
		panic(err)
	}
}

// searchBlob streams a single builds.json blob (from any historical commit), looking for resolved entries whose (tag, arch) pairs match any hole.  Matches are sent to the matches channel tagged with slotIdx (lower = more recent); the coordinator goroutine owns bestSlot/results so no synchronisation is needed here.  ctx is checked between entries: once all initially-unfilled holes are globally filled the caller cancels ctx and this function returns early, letting the caller drain the remaining unread bytes.
//
// Uses encoding/json/v2 (jsontext + jsonv2.UnmarshalDecode) to stream the top-level object one entry at a time, avoiding loading the entire blob into memory at once.
func searchBlob(ctx context.Context, r io.Reader, keyToHoles map[string][]int, slotIdx int, matches chan<- blobMatch) error {
	dec := jsontext.NewDecoder(r)

	// consume the opening '{' of the top-level builds.json object
	if tok, err := dec.ReadToken(); err != nil {
		return err
	} else if tok.Kind() != '{' {
		return fmt.Errorf("expected '{', got %v", tok)
	}

	// minimal shape we care about in each builds.json entry
	// json/v2 discards unknown fields by default
	type entry struct {
		Build struct {
			Arch     string         `json:"arch"`
			Resolved *ocispec.Index `json:"resolved"`
		} `json:"build"`
		Source struct {
			Arches map[string]struct {
				Tags []string `json:"tags"`
			} `json:"arches"`
		} `json:"source"`
	}

	for dec.PeekKind() != '}' {
		if ctx.Err() != nil {
			return nil // all initially-unfilled holes globally filled; return early, caller drains remainder
		}

		// read the buildId key (discard it)
		if _, err := dec.ReadToken(); err != nil {
			return err
		}

		// decode the full value for this buildId into our minimal struct
		var e entry
		if err := jsonv2.UnmarshalDecode(dec, &e); err != nil {
			return err
		}

		if e.Build.Resolved == nil {
			continue
		}

		arch := e.Build.Arch
		archData, ok := e.Source.Arches[arch]
		if !ok {
			continue
		}
		for _, tag := range archData.Tags {
			for _, holeIdx := range keyToHoles[tagArchKey(tag, arch)] {
				matches <- blobMatch{slotIdx: slotIdx, holeIdx: holeIdx, resolved: e.Build.Resolved}
			}
		}
	}

	return nil
}
