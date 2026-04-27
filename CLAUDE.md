# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`occMiner` is an R project (RStudio). No source code exists yet — this is a fresh project shell.

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
