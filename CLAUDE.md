# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Documentation maintenance

After any code change that implements or changes functionality, ask the user whether CLAUDE.md and README.md should be updated to reflect the change before closing the task.

## Project

`occMiner` is an R project (RStudio) that scrapes cactus collection records from two hobbyist databases and geocodes free-text locality strings to decimal coordinates.

### Pipeline (run in order)

```
R/bcss_miner.R            →  data/bcss/all_records.csv          (full DB, hybrid sweep)
R/clcactus_miner.R        →  data/clcactus/all_records.csv      (full DB, all genera)
                                    ↓
R/combineOccs.R           →  data/combined/all_records.csv      (union schema, source-tagged)
                                    ↓
R/cooccurrence_llm.R      →  data/cooccurrence_llm/all_records.csv  (LLM, adds cooccurring_species column)
                                    ↓
R/geocoder.R              →  data/geocoded/<species>.csv       (regex pipeline)
R/geocoder_llm.R          →  data/geocoded_llm/<species>.csv  (LLM, requires GEMINI_API_KEY)
           ↓ (coordinateCleaner reads geocoded/)    ↓ (mapCreator also reads geocoded/)
R/coordinateCleaner.R  →  data/cleaned/           R/mapCreator.R  →  data/kml/, data/shp/
                          data/cleaned_llm/
                                    ↓
R/occTest.R               →  data/occTest/cleaned/
                              data/occTest/cleaned_llm/
                                    ↓
R/compareOccurrences.R    →  data/comparison/   (skipped if data/reference/ is absent)
```

`R/compareOccurrences.R` reads reference shapefiles from `data/reference/` and the LLM-pipeline `occTest` outputs (`data/occTest/cleaned_llm/`), and writes PCA, metrics, niche-space plots, and terrain maps to `data/comparison/`. `run_pipeline.R` invokes it after `occTest.R` but skips it if `data/reference/` is missing (the reference shapefiles are not in git).

> **Downstream caveat:** The miners and `combineOccs.R` emit single CSVs (`data/bcss/all_records.csv`, `data/clcactus/all_records.csv`, `data/combined/all_records.csv`), not per-species CSVs. `geocoder.R`, `geocoder_llm.R`, etc. still expect `data/bcss/<species>.csv` and `data/clcactus/<species>.csv` and will not find data until they are reworked — most naturally, to read `data/combined/all_records.csv` and filter by species. `cooccurrence_llm.R` is currently informational only — it writes a `cooccurring_species` column alongside the combined records, but no downstream script promotes those names into new presence records yet.

Run the full pipeline: `source("run_pipeline.R")`
Run a single script: `Rscript R/<script>.R`

### Species covered

- *Ariocarpus fissuratus*
- *Pilosocereus pachycladus*
- *Thelocactus conothelos*
- *Trichocereus macrogonus*
- *Eulychnia taltalensis*
- *Epithelantha pachyrhiza*
- *Stephanocereus luetzelburgii*
- *Astrophytum myriostigma*
- *Melocactus salvadorensis*
- *Eriosyce wagenknechtii*
- *Rhipsalis hileiabaiana*
- *Opuntia mesacantha*

### bcss_miner notes

- Scrapes the **entire** `fieldnos.bcss.org.uk` field-number database. BCSS has no genus dropdown, and `finder.php` rejects single-word queries — so discovery uses a hybrid two-pass approach.
- **Pass 1 — country sweep**: queries `locality.php?Locality=<country>` for ~250 country/territory names (full ISO 3166-1 list + common aliases like `USA`/`United States`, `UK`/`Britain`, `Czechia`/`Czech Republic`, `Burma`/`Myanmar`, plus historical names like `USSR`, `Yugoslavia`, `Czechoslovakia`). `locality.php` is a case-insensitive substring match (min 3 chars), returns ALL matches in a single (sometimes ~30 MB) HTML response — no pagination. Substring matching means a place named "Algeria" in South Africa is returned by the `Algeria` query, but the final dedupe collapses overlap.
- **Pass 2 — cl-cactus binomial sweep**: only runs if `data/clcactus/.binomials.csv` exists (produced by `clcactus_miner.R`). Queries `finder.php?Plant=<genus>+<epithet>` lowercase for each binomial. ~17k requests at 1 s ≈ 5 h.
- Record format on both endpoints is identical `<p><b>Field number: </b>...<br>...</p>` blocks. The parser uses xpath `following-sibling::node()[1][self::text()]` (NOT `text()[1]`) so empty fields don't bleed in the next field's value.
- Output: single combined CSV `data/bcss/all_records.csv`, appended incrementally. Columns: `field_number, collector, species, locality, altitude, date, notes, source_url` (altitude is BCSS-specific; cl-cactus doesn't have it).
- Final pass dedupes on the tuple `(field_number, collector, tolower(species), locality, altitude, date, notes)`, keeping the first `source_url`. `species` is case-folded in the key because `finder.php` echoes the lowercased URL query (`stapelia cedrimontana`) while `locality.php` preserves the original case (`Stapelia cedrimontana`); since country rows are appended first, `.keep_all` retains the proper-cased species value. Rewrites `all_records.csv` in place.
- Resumable state: `data/bcss/.scrape_state.csv` with `(kind, query, status, n_records, fetched_at)` — `kind` is `country` or `binomial`. Delete the file (or specific rows) to force re-scrape.
- Pacing: 1 s polite-sleep, 5 s × 2^n backoff with 3 retries on errors. RSelenium fallback for Cloudflare retained.
- Logging: `Logs/bcss_miner_YYYYMMDD_HHMMSS.log` per run. Each successful query logs a `Fetched (<size>, ~<n> record blocks) — parsing…` line, then a `parsed N/<total> records` tick every 100 records during parse (matters mainly for large countries like Argentina where one page yields tens of thousands of records).
- Smoke-test env var: `BCSS_QUERY_LIMIT=N` caps total queries across both passes (e.g. `$env:BCSS_QUERY_LIMIT='3'; Rscript R/bcss_miner.R`).

### clcactus_miner notes

- Scrapes the **entire** cl-cactus.com database (~1,220 genera) rather than a hardcoded species list.
- Discovery: `https://www.cl-cactus.com/` front page → `<select name="selGenres">` options (drops empty + `?`).
- Per genus: paginates `genres.asp?genres=<G>&NbrList=80&page=<offset>&OrderBy=Species`, extracts unique binomials (`Genus epithet`) from the species column, filtering out qualifier tokens (e.g. `aff.`, `sp.`, `v.`).
- Per binomial: `fnfinder.asp?Lang=en&Plant=<Genus>+<epithet>` parsed for full schema (`fn_id, field_number, collector, species, genus, locality, date, notes, source_url`). `fn_id` is extracted from the field-number anchor href.
- Output: single combined CSV `data/clcactus/all_records.csv`, appended incrementally so partial progress is preserved.
- Resumable state files (hidden, in `data/clcactus/`):
  - `.binomials.csv` — per-genus discovery cache; reused on rerun so pagination isn't repeated.
  - `.scrape_state.csv` — per-binomial `(genus, binomial, status, n_records, fetched_at)`; binomials marked `done` are skipped on rerun. Delete either file to force re-discovery / re-scrape.
- Pacing: 1 s sleep on success; 5 s × 2^n exponential backoff with 3 retries on errors. Roughly 7 h for a full DB run.
- Logging: `Logs/clcactus_miner_YYYYMMDD_HHMMSS.log` per run.
- Smoke-test env var: `CLCACTUS_GENUS_LIMIT=N` restricts the run to the first N genera (e.g. `$env:CLCACTUS_GENUS_LIMIT='1'; Rscript R/clcactus_miner.R`).

### combineOccs notes

- Reads `data/bcss/all_records.csv` and `data/clcactus/all_records.csv` and writes the union to `data/combined/all_records.csv`.
- Stops with a clear error if either input is missing — it does not attempt a partial merge.
- Both inputs are read with `col_types = cols(.default = col_character())` so the 20-digit clcactus `fn_id` round-trips intact (auto type inference would coerce it to a lossy double).
- Output schema (in order): `source, fn_id, field_number, collector, species, genus, locality, altitude, date, notes, source_url`. BCSS rows get `NA` for `fn_id` and `genus`; clcactus rows get `NA` for `altitude`. `source` is `bcss` or `clcactus`.
- No deduplication across sources — the same plant scraped from both DBs appears twice, distinguished by `source`. Downstream code that wants a single record per plant must dedupe itself.
- No filtering — every row from both DBs is kept. The "Species covered" list does not apply here; that filter (if needed) lives downstream.
- Logs a one-line summary to stdout (`bcss rows: N / clcactus rows: M / combined rows: N+M`). No log file.

### LLM pipeline notes

- Model: `gemini-3.1-flash-lite-preview` (free tier, 15 RPM)
- Localities batched 50 per API call; results cached to avoid duplicate calls
- Add `GEMINI_API_KEY=your_key_here` to `~/.Renviron`
- Each run writes a timestamped log to `Logs/geocoder_llm_YYYYMMDD_HHMMSS.log` with raw LLM input/output per batch

### cooccurrence_llm notes

- Reads `data/combined/all_records.csv`; writes `data/cooccurrence_llm/all_records.csv` (same schema plus a new `cooccurring_species` column — semicolon-joined list, empty string when there are no co-occurrences).
- Same Gemini wiring as `geocoder_llm.R` (model, throttle, retry, log format), except batches are larger: `CHUNK_SIZE = 150` items per request and `maxOutputTokens = 16384` (sized to the ~250k TPM / 15 RPM free-tier limits — current peak is roughly 180k TPM). Each batch carries `{i, focal_species, notes}`; the prompt asks for `{i, species: [...]}` back.
- Cache is keyed on the `notes` string alone, so identical notes across records cost one API call.
- Cache is **disk-persisted** at `data/cooccurrence_llm/.cache.csv` (header `notes, cooccurring_species`; the latter is the semicolon-joined output, empty string when nothing was extracted). Appended to after every successful batch — survives a killed R process or a hit-the-quota stop. On startup the script loads it and filters `notes_jobs` to skip cached entries. Transient-failure batches (network blips, exhausted `MAX_RETRIES`) are **not** cached, so a future run retries them.
- **Quota-aware exit**. A Gemini 429 with `error.status == "RESOURCE_EXHAUSTED"` and either a `RetryInfo.retryDelay > 300 s` or a `QuotaFailure.quotaId` matching `PerDay`/`Daily` is treated as a daily-quota hit. `req_retry`'s `is_transient` returns `FALSE` for these so retries stop immediately; the outer loop catches the error, sets a `quota_exhausted` flag, logs the event, prints a clean message, and breaks out of the main batch loop. The partial `all_records.csv` is still written using whatever is in the cache. Re-run the script later (e.g. tomorrow) to resume from the cache. Short throttle 429s (no `PerDay` quotaId, small `retryDelay`) are still treated as transient and retried as before.
- `run_pipeline.R` preserves `data/cooccurrence_llm/.cache.csv` across full pipeline reruns (same pattern as `data/comparison/PCA.rda`) — the rest of the `data/cooccurrence_llm/` directory is cleaned.
- Prompt rules:
  - Co-occurrence must be **explicitly signaled** by a connecting phrase (`with`, `together with`, `growing with`, `growing among`, `in association with`, `associated with`, `amongst`, `accompanied by`, `alongside`, `near`, `beside`, …). Bare names in quotes, `(= Genus species)` synonyms, `!` / `=` / `syn.` markers, parenthetical authorities, and the focal species itself are all excluded.
  - **Verbatim preservation**: misspellings, infraspecific ranks (`ssp.`, `subsp.`, `var.`, `v.`, `f.`, `fma.`), `cf.`/`aff.` qualifiers, and bare `sp.` are all kept as written. The only normalization allowed is expanding an abbreviated genus (`G.spegazzinnii` → `Gymnocalycium spegazzinnii`, typo preserved).
  - Field numbers / collector codes (`REP329-331f`, `BB1182.01`, `=BLMT63`, `JO323`) and generic plant references (`grasses`, `bushes`) are dropped.
- Logging: `Logs/cooccurrence_llm_YYYYMMDD_HHMMSS.log`, same `--- INPUT --- / --- OUTPUT ---` block format as `geocoder_llm.R`.
- Smoke-test env var: `COOCCURRENCE_LIMIT=N` caps the number of unique notes sent to Gemini (e.g. `$env:COOCCURRENCE_LIMIT='100'; Rscript R/cooccurrence_llm.R`). Useful for a first-pass sanity check before committing to a full run (~33k unique notes, ~45 min at 15 RPM).

### geocode_type values

| Value | Set by | Meaning |
|---|---|---|
| `direct` | both | Clean address geocoded via OSM → ArcGIS |
| `direction_only` | both | Directional phrase detected but no distance; centroid used |
| `offset_adjusted` | both | Directional phrase with distance; coordinates displaced by haversine |
| `llm_approximate` | LLM only | OSM + ArcGIS failed; Gemini fallback coords used |
| `failed` | both | All methods failed; lat/lon = NA |

### occTest notes

- Predictor raster: `data/predictors/ase_UKESM1-0-LL_current.tif` (layers 1–26 used)
- `filterAtlas = FALSE`, `errorAcceptance = "strict"`
- Outputs per species: `.kml`, `.shp`, `.rda`, `.jpg`, `filterSummary.csv`

### compareOccurrences notes

- Reference shapefiles named `<Species>_envT_extF.shp` under `data/reference/` (not in git). The active subset is copied out of `data/referencePool/` (a 1,038-species library, also not in git) — when adding/removing species, copy their `*_envT_extF.*` sidecars across so `sf::st_read` finds the full set.
- Comparison runs for **both** pipelines per species: `data/occTest/cleaned/<species>.shp` (regex) and `data/occTest/cleaned_llm/<species>.shp` (LLM). Reference shapefile is loaded once per species and shared across pipelines.
- PCA fitted on 100,000 random raster samples; cached to `data/comparison/PCA.rda` and reused on subsequent runs (delete the file to refit)
- `summary.csv` is long-format: one row per species × pipeline (24 rows total for the current 12 species). Columns: `species`, `pipeline` (`cleaned` or `cleaned_llm`), `n_ref`, `n_new`, `n_combined`, `n_pct_increase`, `range_*` and `niche_*` triplets (`ref`, `new`, `combined`, `pct_increase`); `pct_increase = (combined − ref) / ref × 100`
- Per-(species × pipeline) PNGs: `<species>_<pipeline>.png` (PC1/PC2 niche plot with Reference / New / Combined hulls) and `<species>_<pipeline>_map.png` (OpenTopoMap basemap with points coloured by source, shaped by `geocode_type`, plus three MCP polygons)
- Per-species PDF: `<species>.pdf` — US letter portrait (8.5 × 11 in), top half is LLM pipeline, bottom half is regex pipeline; each half is map (left) + niche plot (right) above a 3 × 4 stats table (n / range km² / niche × Reference / New / Combined / +%). Built with `ggpubr::ggarrange` + `ggpubr::ggtexttable` and `cairo_pdf` device.

### Dependencies

```r
install.packages(c(
  "httr", "rvest",                      # scraping
  "httr2", "jsonlite",                  # LLM pipeline
  "tidygeocoder",                       # geocoding
  "CoordinateCleaner",                  # coordinate cleaning
  "terra", "sf",                        # spatial output
  "occTest", "ggpubr",                  # occurrence testing
  "geometry", "maptiles", "tidyterra",  # comparison plots
  "dplyr", "readr", "stringr", "purrr"  # data wrangling
))
# RSelenium: optional fallback for BCSS if Cloudflare blocks direct requests
```

## R Project conventions

- Indentation: 2 spaces (no tabs)
- Encoding: UTF-8
- LaTeX weaving: Sweave / pdfLaTeX

## Common commands

```r
# Install package dependencies (once DESCRIPTION or renv is added)
renv::restore()          # if renv is used
install.packages(c(...)) # or direct install

# Run a script
Rscript path/to/script.R

# Run tests (testthat)
testthat::test_dir("tests/")
testthat::test_file("tests/testthat/test-foo.R")

# Lint
lintr::lint_dir("R/")
```
