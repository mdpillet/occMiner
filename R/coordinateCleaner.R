library(CoordinateCleaner)
library(readr)
library(dplyr)

pipelines <- list(
  list(in_dir = "data/geocoded",     out_dir = "data/cleaned"),
  list(in_dir = "data/geocoded_llm", out_dir = "data/cleaned_llm")
)

for (pl in pipelines) {
  dir.create(pl$out_dir, recursive = TRUE, showWarnings = FALSE)

  csv_files <- list.files(pl$in_dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(csv_files) == 0) {
    message("No CSVs found in ", pl$in_dir, " — skipping")
    next
  }

  for (csv_path in csv_files) {
    filename <- basename(csv_path)
    data     <- read_csv(csv_path, show_col_types = FALSE)
    n_input  <- nrow(data)

    # CoordinateCleaner requires non-NA coordinates
    data <- filter(data, !is.na(lat), !is.na(lon))
    message(filename, ": ", n_input, " records, ",
            n_input - nrow(data), " dropped (NA coords), ",
            nrow(data), " sent to cleaner")

    flags <- clean_coordinates(
      data,
      lon        = "lon",
      lat        = "lat",
      species    = "species",
      seas_scale = 50,
      tests      = c("capitals", "centroids", "equal", "gbif",
                     "institutions", "seas", "zeros")
    )

    cleaned <- filter(flags, .summary == TRUE)
    message("  ", nrow(flags) - nrow(cleaned), " record(s) flagged by CoordinateCleaner")

    # Drop flag columns added by clean_coordinates (all start with ".")
    cleaned <- select(cleaned, !starts_with("."))

    # New World bounding box
    before_bbox <- nrow(cleaned)
    cleaned <- filter(cleaned, lat >= -60, lat <= 60, lon >= -135, lon <= -30)
    message("  ", before_bbox - nrow(cleaned), " record(s) outside New World bounding box")

    out_path <- file.path(pl$out_dir, filename)
    write_csv(cleaned, out_path)
    message("  Written ", nrow(cleaned), " records to ", out_path)
  }
}

message("Done.")
