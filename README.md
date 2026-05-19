# occMiner

Scrapes cactus collection records from two hobbyist databases and geocodes the free-text locality strings to decimal coordinates. Built in R.

## Species covered

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

## Pipeline

```
bcss_miner.R          →  data/bcss/all_records.csv      (full DB, hybrid sweep)
clcactus_miner.R      →  data/clcactus/all_records.csv  (full DB, all genera)
                                ↓
combineOccs.R         →  data/combined/all_records.csv  (union, source-tagged)
                                ↓
cooccurrence_llm.R    →  data/cooccurrence_llm/all_records.csv  (LLM, adds cooccurring_species)
                                ↓
geocoder.R            →  data/geocoded/<species>.csv      (regex pipeline)
geocoder_llm.R        →  data/geocoded_llm/<species>.csv  (LLM pipeline)
        ↓ (reads geocoded/)                    ↓ (also reads geocoded/)
coordinateCleaner.R   →  data/cleaned/         mapCreator.R  →  data/kml/
                          data/cleaned_llm/                      data/shp/
                                ↓
occTest.R             →  data/occTest/cleaned/
                          data/occTest/cleaned_llm/
                                ↓ (skipped if data/reference/ is absent)
compareOccurrences.R  →  data/comparison/
```

Run the full pipeline from the project root with:

```r
source("run_pipeline.R")
```

Or run individual scripts with `Rscript R/<script>.R`.

> **Downstream caveat:** Both miners now write single combined CSVs (`data/bcss/all_records.csv` and `data/clcactus/all_records.csv`), not per-species CSVs. The geocoding / cleaning / occTest stages still expect `data/bcss/<species>.csv` and `data/clcactus/<species>.csv` and will not pick up the new data until they are reworked to read the combined files and filter by species. `cooccurrence_llm.R` is currently informational only — it writes a `cooccurring_species` column alongside the combined records, but no downstream script promotes those names into new presence records yet.

## Data sources

| Script | Source | URL pattern |
|---|---|---|
| `bcss_miner.R` | British Cactus & Succulent Society field number database | Country sweep (substring match, no pagination): `fieldnos.bcss.org.uk/locality.php?Locality=<Country>`; per-species (Pass 2): `fieldnos.bcss.org.uk/finder.php?Plant=<genus>+<species>` |
| `clcactus_miner.R` | CL-Cactus field number finder | Genus list: `cl-cactus.com/` (front-page `<select name="selGenres">`); per-genus listing: `cl-cactus.com/genres.asp?genres=<Genus>`; per-species records: `cl-cactus.com/fnfinder.asp?Lang=en&Plant=<Genus>+<species>` |

BCSS scraping uses `httr` with browser headers and falls back to RSelenium if a non-200 response is returned (Cloudflare protection). cl-cactus.com is fetched directly via `httr`.

`bcss_miner.R` scrapes the **whole** BCSS database via a two-pass hybrid sweep. Pass 1 queries `locality.php` once per country/territory using a hardcoded ~250-entry ISO 3166-1 list (plus common aliases like `USA`/`United States` and `UK`/`Britain`, and historical names like `USSR`, `Yugoslavia`); each query is a case-insensitive substring match with no pagination, so a single call returns every matching record (responses can be ~30 MB for big countries). Pass 2 — only triggered if `data/clcactus/.binomials.csv` exists — queries `finder.php` once per cl-cactus-discovered binomial to catch records whose locality strings don't contain a country name. A final dedupe pass collapses duplicates (substring overlap across country queries, plus cross-pass overlap between country and binomial sweeps) on the full record tuple with `species` case-folded — necessary because `finder.php` lowercases the species name in its response while `locality.php` preserves the original case. Output: `data/bcss/all_records.csv` with columns `field_number, collector, species, locality, altitude, date, notes, source_url`. State file `data/bcss/.scrape_state.csv` tracks per-query completion (`kind = country` or `binomial`) — delete to force re-scrape. Smoke-test env var: `BCSS_QUERY_LIMIT=N`. Pass 1 takes ~5–20 min; Pass 2 adds ~5 h. Logs at `Logs/bcss_miner_YYYYMMDD_HHMMSS.log` — each successful query logs its fetched response size and record-block count, with a progress tick every 100 records during parse (useful for big-country pages like Argentina where one response yields tens of thousands of records).

`clcactus_miner.R` scrapes the **whole** cl-cactus database: it discovers all genera from the front-page dropdown, enumerates the binomials in each genus via the paginated `genres.asp` listing, then fetches every binomial's full records via `fnfinder.asp`. Output is appended incrementally to `data/clcactus/all_records.csv` so partial progress survives interruption. State files `data/clcactus/.binomials.csv` (per-genus discovery cache) and `data/clcactus/.scrape_state.csv` (per-binomial completion) make reruns resumable — delete them to force a fresh scrape. Set the env var `CLCACTUS_GENUS_LIMIT=N` to restrict a run to the first N genera (useful for smoke tests). A full scrape is roughly 7 hours at 1 s polite-sleep with exponential backoff on errors; each run writes a timestamped log to `Logs/clcactus_miner_YYYYMMDD_HHMMSS.log`.

## Output schema

All geocoded CSVs share the same columns:

| Column | Description |
|---|---|
| `field_number` | Collector field number |
| `collector` | Collector name |
| `species` | Taxon name |
| `locality` | Raw locality string as scraped |
| `altitude` | Altitude string as scraped |
| `date` | Collection date |
| `notes` | Additional notes |
| `source` | Source database (`bcss` or `clcactus`) |
| `geocode_query` | The string actually submitted to the geocoder |
| `geocode_type` | How coordinates were obtained (see below) |
| `lat` | Decimal latitude (WGS 84), or `NA` if geocoding failed |
| `lon` | Decimal longitude (WGS 84), or `NA` if geocoding failed |

## Geocode type workflows

Both pipelines assign each record a `geocode_type` that describes how (or whether) coordinates were obtained. The workflows differ between the two scripts.

### `geocoder.R` (regex pipeline)

Locality strings are cleaned and parsed entirely with regular expressions before being submitted to OSM (Nominatim) and, if that fails, ArcGIS.

#### `direct`
The locality string was geocodable as-is after light cleaning (stripping elevation tokens, fixing common misspellings, reformatting "Country: State (detail)" notation). The cleaned string is submitted directly to OSM → ArcGIS.

> Example locality: `"Cuatro Ciénegas, Coahuila, Mexico"`
> Query submitted: `"Cuatro Ciénegas, Coahuila, Mexico"`

#### `direction_only`
A directional phrase was detected (e.g. "North of X", "W of X") but **no distance** was given, so the offset cannot be computed. The base place name is extracted and geocoded; the returned coordinates are the centroid of that place, not the actual collection site.

> Example locality: `"North of Sierra de la Paila, Coahuila, Mexico"`
> Query submitted: `"Sierra de la Paila, Coahuila, Mexico"` (direction discarded)

#### `offset_adjusted`
A directional phrase **with a distance** was detected (e.g. "5 km NW of Saltillo"). The base place is geocoded first, then the coordinates are displaced along the stated bearing using the spherical haversine formula.

> Example locality: `"5km N of Hot Springs, Texas, USA"`
> Query submitted: `"Hot Springs, Texas, USA"` → result shifted 5 km north

#### `failed`
The locality string was too vague to parse, or both OSM and ArcGIS returned no result. `lat` and `lon` are `NA`.

---

### `geocoder_llm.R` (LLM pipeline)

Locality strings are first interpreted by Gemini 3.1 Flash Lite, which parses each string into a structured JSON object containing a cleaned address, an optional directional offset, and fallback coordinates. Unique locality strings are sent in batches of up to 50 per API request. Parsed results are cached so that no locality incurs more than one API call.

```
locality strings (batched, up to 50 per call)
        ↓
  Gemini 3.1 Flash Lite
        ↓ returns per locality:
          address       – clean geocodeable string (or null)
          offset        – {base, distance_km, direction} (or null)
          fallback_lat  – LLM best-guess coordinate
          fallback_lon
        ↓
  OSM → ArcGIS geocoding (on unique queries)
        ↓
  bearing offset applied where offset present
        ↓
  LLM fallback coordinates used if OSM + ArcGIS both fail
```

The `geocode_type` values are identical to the regex pipeline plus one addition:

#### `direct`
Gemini returned a clean address with no directional offset. Geocoded via OSM → ArcGIS.

#### `direction_only`
Gemini detected a directional phrase but returned no distance. The base place is geocoded and its centroid used.

#### `offset_adjusted`
Gemini detected a directional phrase with a distance. The base place is geocoded and coordinates are displaced by the stated bearing and distance.

#### `llm_approximate`
OSM and ArcGIS both failed to geocode the query, but Gemini's `fallback_lat`/`fallback_lon` (returned in the same API call as the parse result) are available and used instead. Accuracy is lower than geocoder-derived coordinates.

#### `failed`
All methods failed: the query returned no geocoder result and Gemini returned null fallback coordinates. `lat` and `lon` are `NA`.

---

### Choosing between pipelines

| | `geocoder.R` | `geocoder_llm.R` |
|---|---|---|
| External dependencies | None beyond R packages | Gemini API key |
| API calls | 0 (uses free Nominatim/ArcGIS) | 1 per ~50 unique localities |
| Directional parsing | Regex (fast, deterministic) | LLM (flexible, handles unusual phrasing) |
| Fallback for failed geocodes | None — record marked `failed` | LLM approximate coordinates |
| Rate limit | Nominatim: 1 req/s | Gemini free tier: 15 req/min |

## Co-occurrence extraction

`cooccurrence_llm.R` reads `data/combined/all_records.csv` and asks Gemini 3.1 Flash Lite to extract co-occurring species names from the free-text `notes` field of each record (e.g. *"together with Parodia malyana"*, *"Found in association with Opuntia fragilis and O. cymochila"*). Output is written to `data/cooccurrence_llm/all_records.csv` — the same schema as the combined records, plus one new column:

| Column | Description |
|---|---|
| `cooccurring_species` | Semicolon-joined list of co-occurring species names extracted from `notes`. Empty string when there are none. |

### Prompt rules

- **Co-occurrence must be explicitly signaled** by a connecting phrase: `with`, `together with`, `growing with`, `growing among`, `in association with`, `associated with`, `amongst`, `accompanied by`, `alongside`, `near`, `beside`, and similar. Names in quotes by themselves, `(= Genus species)` synonyms, `!` / `=` / `syn.` markers, parenthetical authorities, and the focal species echoed back in notes are all excluded.
- **Verbatim preservation.** Misspellings, infraspecific ranks (`ssp.`, `subsp.`, `var.`, `v.`, `f.`, `fma.`), `cf.` / `aff.` qualifiers, and bare `sp.` are kept exactly as written. The only normalization allowed is expanding an abbreviated genus (e.g. `G.spegazzinnii` → `Gymnocalycium spegazzinnii`, typo preserved).
- **Field numbers / collector codes excluded.** Anything matching `REP329-331f`, `BB1182.01`, `=BLMT63`, `JO323`, etc. is dropped. Generic plant references (`grasses`, `bushes`) are dropped.

### Implementation

- Same Gemini wiring as `geocoder_llm.R`: model `gemini-3.1-flash-lite-preview`, batches of up to 50 `{focal_species, notes}` items per API call, 15 RPM throttle, 3 retries with exponential backoff plus indefinite outer retry, timestamped log at `Logs/cooccurrence_llm_YYYYMMDD_HHMMSS.log`.
- Cache is keyed on the `notes` string alone, so identical notes across records cost only one API call. On the current dataset, ~351k records collapse to ~34k unique non-empty notes (~45 min API time at the free-tier rate).
- Smoke-test env var: `COOCCURRENCE_LIMIT=N` caps the number of unique notes sent to Gemini (`$env:COOCCURRENCE_LIMIT='100'; Rscript R/cooccurrence_llm.R`).

## Coordinate cleaning

`coordinateCleaner.R` reads the geocoded CSVs from both pipelines and removes suspect records using the `CoordinateCleaner` package. Records with `NA` coordinates are dropped first, then seven tests are run:

| Test | What it flags |
|---|---|
| `zeros` | lat = 0 or lon = 0 |
| `equal` | lat == lon |
| `gbif` | Coordinates at the GBIF headquarters |
| `seas` | Records in the ocean |
| `capitals` | Records near country/province capitals |
| `centroids` | Records at country/province centroids |
| `institutions` | Records near biodiversity institutions |

Only records passing all tests (`errorAcceptance = "strict"`) are kept. A New World bounding box (lat −60 to 60, lon −135 to −30) is applied as a final filter.

Output: `data/cleaned/<species>.csv` and `data/cleaned_llm/<species>.csv`.

## Map output

`mapCreator.R` converts geocoded CSVs to KML and shapefile (SHP) for visualisation in Google Earth, QGIS, or any GIS tool. It reads directly from the geocoded outputs (not the cleaned ones) and produces one file per species per pipeline:

```
data/kml/
  geocoded/
    ariocarpus_fissuratus.kml
    pilosocereus_pachycladus.kml
    thelocactus_conothelos.kml
    trichocereus_macrogonus.kml
    ... (one per species, 12 total)
  geocoded_llm/
    (same files)
data/shp/
  geocoded/
    ariocarpus_fissuratus.shp  (+ .dbf, .prj, .shx)
    ... (one per species, 12 total)
  geocoded_llm/
    (same files)
```

Each placemark is colour-coded by `geocode_type` and includes a metadata table (field number, collector, locality, date, source, geocode query and type) in its description popup.

| `geocode_type` | Colour |
|---|---|
| `direct` | Green |
| `direction_only` | Orange |
| `offset_adjusted` | Blue |
| `llm_approximate` | Purple |
| `failed` | Red |

Records with no coordinates (`lat`/`lon` = `NA`) are excluded.

## Occurrence testing

`occTest.R` runs the `occTest` package against an environmental raster to detect and remove further suspect occurrences. It reads from `data/cleaned/` and `data/cleaned_llm/` and runs one test configuration per species (env outliers ON, raster layers 1–26, `errorAcceptance = "strict"`).

Predictor raster: `data/predictors/ase_UKESM1-0-LL_current.tif` (layers 1–26).

Output per species per pipeline (in `data/occTest/cleaned/` and `data/occTest/cleaned_llm/`):

| File | Contents |
|---|---|
| `<species>.kml` | Filtered occurrences (KML) |
| `<species>.shp` | Filtered occurrences (shapefile) |
| `<species>.rda` | Raw `occTest` and `occFilter` R objects |
| `<species>.jpg` | Diagnostic plots |
| `filterSummary.csv` | Record counts before and after filtering |

## Comparison

`compareOccurrences.R` compares the new filtered occurrences against a reference dataset and computes range and niche size metrics, a niche-space plot, and a terrain map per species. The same comparison is run for **both** pipeline outputs (`data/occTest/cleaned/` and `data/occTest/cleaned_llm/`) so the regex and LLM pipelines can be evaluated against the same reference baseline. It runs as the final step of `run_pipeline.R`, but is skipped automatically if `data/reference/` is not present (the reference shapefiles are not checked into git).

**Inputs:**
- Reference shapefiles in `data/reference/<Species>_envT_extF.shp` (one per species, not checked into git). The active subset is copied from `data/referencePool/`, a 1,038-species library that holds reference shapefiles for the full project pool (also not in git).
- Filtered shapefiles from `data/occTest/cleaned/` and `data/occTest/cleaned_llm/`
- Environmental raster `data/predictors/ase_UKESM1-0-LL_current.tif`

**Outputs** (in `data/comparison/`):

| File | Contents |
|---|---|
| `PCA.rda` | PCA model fitted on 100,000 random raster samples. Cached and reused on subsequent runs; delete to refit. |
| `<species>_<pipeline>.png` | PC1/PC2 niche-space plot for one pipeline (`cleaned` or `cleaned_llm`) with Reference, New, and Combined convex hulls |
| `<species>_<pipeline>_map.png` | OpenTopoMap terrain basemap for one pipeline with points coloured by source (Reference / New), shaped by `geocode_type`, plus MCPs for reference, new, and combined |
| `<species>.pdf` | Per-species report (US letter portrait): top half is the LLM pipeline, bottom half is the regex pipeline. Each half lays the range map (left) and the niche plot (right) above a 3 × 4 stats table summarising n / range / niche for Reference, New, and Combined plus the combined-vs-reference percentage increase. |
| `summary.csv` | Per-species per-pipeline metrics (one row per species × pipeline; see below) |

`summary.csv` columns: `species`, `pipeline` (`cleaned` or `cleaned_llm`), `n_ref`, `n_new`, `n_combined`, `n_pct_increase`, `range_ref_km2`, `range_new_km2`, `range_combined_km2`, `range_pct_increase`, `niche_ref`, `niche_new`, `niche_combined`, `niche_pct_increase`. Each `*_combined` value is the metric computed on the union of reference and new points for that pipeline; `*_pct_increase` is `(combined − ref) / ref × 100`.

The script uses Mollweide projection for range area calculations and a convex-hull approach for niche size (requires ≥ 3 points per dataset).

## Setup

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
```

RSelenium is only needed as a fallback for BCSS if Cloudflare blocks the direct request.

### Gemini API key (LLM pipeline only)

Add to `~/.Renviron`:

```
GEMINI_API_KEY=your_key_here
```

Then restart R or run `readRenviron("~/.Renviron")`.

The script uses the **Gemini 3.1 Flash Lite Preview** model (`gemini-3.1-flash-lite-preview`), which is available on the free tier. Rate limiting is handled automatically via `httr2::req_throttle()` (15 RPM). Failed requests are retried up to 3 times with exponential backoff (10 s, 20 s, 40 s).
