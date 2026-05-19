library(dplyr)
library(readr)

BCSS_CSV     <- file.path("data", "bcss",     "all_records.csv")
CLCACTUS_CSV <- file.path("data", "clcactus", "all_records.csv")
OUT_DIR      <- file.path("data", "combined")
OUT_CSV      <- file.path(OUT_DIR, "all_records.csv")

UNION_COLS <- c("source", "fn_id", "field_number", "collector", "species",
                "genus", "locality", "altitude", "date", "notes", "source_url")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

stopifnot(
  "data/bcss/all_records.csv not found — run R/bcss_miner.R first"          = file.exists(BCSS_CSV),
  "data/clcactus/all_records.csv not found — run R/clcactus_miner.R first"  = file.exists(CLCACTUS_CSV)
)

read_records <- function(path, source_tag) {
  df <- read_csv(path, show_col_types = FALSE,
                 locale = locale(encoding = "UTF-8"),
                 col_types = cols(.default = col_character()))
  df$source <- source_tag
  missing <- setdiff(UNION_COLS, names(df))
  for (col in missing) df[[col]] <- NA_character_
  df[, UNION_COLS]
}

bcss     <- read_records(BCSS_CSV,     "bcss")
clcactus <- read_records(CLCACTUS_CSV, "clcactus")

combined <- bind_rows(bcss, clcactus)

write_csv(combined, OUT_CSV, na = "NA")

cat(sprintf("bcss     rows: %d\n", nrow(bcss)))
cat(sprintf("clcactus rows: %d\n", nrow(clcactus)))
cat(sprintf("combined rows: %d -> %s\n", nrow(combined), OUT_CSV))
