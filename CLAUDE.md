# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`occMiner` is an R project (RStudio) that scrapes cactus collection records from two hobbyist databases and geocodes free-text locality strings to decimal coordinates.

### Pipeline (run in order)

```
R/bcss_miner.R       →  data/bcss/<species>.csv
R/clcactus_miner.R   →  data/clcactus/<species>.csv
                              ↓
R/geocoder.R         →  data/geocoded/<species>.csv       (regex pipeline)
R/geocoder_llm.R     →  data/geocoded_llm/<species>.csv  (LLM pipeline, requires GEMINI_API_KEY)
                              ↓
R/mapCreator.R       →  data/kml/geocoded/<species>.kml
                         data/kml/geocoded_llm/<species>.kml
                         data/shp/geocoded/<species>.shp
                         data/shp/geocoded_llm/<species>.shp
```

Run each script from the project root: `Rscript R/<script>.R`

### Species covered

- *Ariocarpus fissuratus*
- *Pilosocereus chrysostele*
- *Pilosocereus pachycladus*
- *Thelocactus conothelos*

### LLM pipeline notes

- Model: `gemini-3.1-flash-lite-preview` (free tier, 15 RPM)
- Localities batched 50 per API call; results cached to avoid duplicate calls
- Add `GEMINI_API_KEY=your_key_here` to `~/.Renviron`

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
