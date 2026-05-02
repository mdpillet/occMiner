# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Documentation maintenance

After any code change that implements or changes functionality, ask the user whether CLAUDE.md and README.md should be updated to reflect the change before closing the task.

## Project

`occMiner` is an R project (RStudio) that scrapes cactus collection records from two hobbyist databases and geocodes free-text locality strings to decimal coordinates.

### Pipeline (run in order)

```
R/bcss_miner.R            →  data/bcss/<species>.csv
R/clcactus_miner.R        →  data/clcactus/<species>.csv
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

### LLM pipeline notes

- Model: `gemini-3.1-flash-lite-preview` (free tier, 15 RPM)
- Localities batched 50 per API call; results cached to avoid duplicate calls
- Add `GEMINI_API_KEY=your_key_here` to `~/.Renviron`
- Each run writes a timestamped log to `Logs/geocoder_llm_YYYYMMDD_HHMMSS.log` with raw LLM input/output per batch

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
