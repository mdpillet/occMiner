# Stricter geographic outlier flagging — options

This document collects approaches for making `occTest` flag geographic
outliers more strictly. Nothing here is implemented yet — these are
candidates for evaluation against the existing pipeline.

## Current configuration (`R/occTest.R`)

- `customSettings <- defaultSettings()` — i.e. all defaults
- `customSettings$analysisSettings$filterAtlas <- FALSE`
- Predictor raster: layers 1–26 of `data/predictors/ase_UKESM1-0-LL_current.tif`,
  reprojected to EPSG:4326
- `occFilter(df = occTest_result, errorAcceptance = "strict")`
  (i.e. `errorThreshold = 0.2` — drop a point if it fails >20 % of tests)

The six approaches below are not mutually exclusive.
**A + C** is the lightest-touch combination; **A + B + D** is more
aggressive; **E + F** is the heaviest.

---

## A. Tighten the existing geo-outlier knobs

**What it changes**

In `analysisSettings$geoOutliers`:

| Setting           | Current default | Suggested |
|-------------------|-----------------|-----------|
| `alpha.parameter` | 2               | 1 (or 0.5) |
| `mcp_percSample`  | 95              | 80–85      |

**Effect.** Lower alpha → tighter, more concave alpha-hull. Lower MCP
percentile → fewer points are considered "core". Both push more points
outside the accepted geographic envelope, so more get flagged by the
existing tests.

**Cost / risk.** Self-contained — no new tests are added and no external
dependencies. Risk is over-flagging legitimately disjunct sub-populations
(real range gaps look like outliers under a tight alpha-hull).

**Effort.** Two knob tweaks in `customSettings$analysisSettings`.

---

## B. Drop `errorThreshold` below `"strict"`

**What it changes.** Replace

```r
occFilter(df = occTest_result, errorAcceptance = "strict")
```

with an explicit threshold:

```r
occFilter(df = occTest_result, errorThreshold = 0.1)
```

**Effect.** `"strict"` corresponds to `errorThreshold = 0.2` (drop a point
if more than 20 % of tests fail). At `0.1`, a point is dropped if it fails
just one or two tests instead of needing several. Doesn't change *which*
tests run — only how lenient the vote is.

**Cost / risk.** Slight risk of dropping otherwise-valid points that
trip a single sensitive test. Cheap to roll back.

**Effort.** One-line change to the `occFilter()` call.

---

## C. Tighten precision / uncertainty filters

**What it changes**

In `analysisSettings$geoenvLowAccuracy`:

| Setting                   | Current default | Suggested |
|---------------------------|-----------------|-----------|
| `elev.quality.threshold`  | 100 m           | 50 m       |

In `analysisSettings$geoSettings`:

| Setting                          | Current default | Suggested |
|----------------------------------|-----------------|-----------|
| `coordinate.decimal.precision`   | 4 (~11 m)       | 4 (verify) |

**Effect.** Drops coarsely-geocoded points (e.g. those truncated to 0.01°
or 0.1°, town-centroid hits with high uncertainty) *before* any spatial
test. Especially relevant to the regex / LLM pipelines that fall back to
town centroids when a precise locality string can't be parsed.

**Cost / risk.** Removes precision-flagged points even if they are
in-range — a legitimate trade-off for niche/range work where coordinate
precision matters more than sample size.

**Effort.** A couple of knob tweaks in `customSettings$analysisSettings`.

---

## D. Native-range gating via `countryStatusRange`

**What it changes.** Set

```r
customSettings$analysisSettings$countryStatusRange$excludeNotmatchCountry <- TRUE
```

**Effect.** Adds a hard "is this point in a country where the species is
recorded?" check to the test battery. A point in a country not in the
species' known range becomes a fail vote, contributing to the
`errorThreshold` total.

**Cost / risk.** Especially valuable for *Pilosocereus* species that are
geographically restricted (Brazil endemics, etc.) but show up in hobbyist
records assigned to neighboring countries. Risk: range databases are
incomplete; a real but undocumented country presence will be flagged.

**Effort.** One setting flip; relies on occTest's bundled range data, no
new dependency.

---

## E. Re-enable `filterAtlas`

**What it changes.** Flip

```r
customSettings$analysisSettings$filterAtlas <- TRUE
```

(currently `FALSE` in `R/occTest.R`).

**Effect.** Adds occTest's GBIF-atlas-based native-range check. Stronger
than `countryStatusRange` because it uses point-level atlas data instead
of country-level lists.

**Cost / risk.** External dependency on GBIF data fetches; runs slower;
may fail offline or rate-limit. The atlas itself can be sparse for some
taxa, so apparent "outliers" may simply reflect under-sampling rather
than actual misidentification.

**Effort.** One setting flip; potentially infrastructural depending on
how occTest fetches atlas data.

---

## F. Iterative two-pass filter

**What it changes.** Replace the single `occTest → occFilter` call per
species with two passes:

1. Run `occTest` → `occFilter` (current logic).
2. Re-run `occTest` on the survivors.
3. Re-run `occFilter` on the second result.

**Effect.** Geographic outlier statistics (alpha-hull, IQR-on-coords,
spatial autocorrelation) are *recomputed* against the cleaner point cloud
on the second pass, so points that were "hiding" inside the original
noisy hull get exposed. Pure structural change — no parameter tweaks
needed.

**Cost / risk.** Doubles per-species runtime. Risk of erosion: each pass
removes the geographic edge of the cloud, so iterating to convergence
would shrink the range arbitrarily. Capping at two passes mitigates
this.

**Effort.** Loop change in `R/occTest.R`; the per-species block becomes
a small function called twice.
