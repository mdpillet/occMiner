library(terra)
library(occTest)
library(ggpubr)
library(readr)
library(dplyr)

# Load raster — layers 1-26 only (environment, no extent layers)
env    <- rast("data/predictors/ase_UKESM1-0-LL_current.tif")[[1:26]]
envProj <- project(env, "EPSG:4326")

customSettings <- defaultSettings()
customSettings$analysisSettings$filterAtlas <- FALSE

pipelines <- list(
  list(in_dir = "data/cleaned",     out_dir = "data/occTest/cleaned"),
  list(in_dir = "data/cleaned_llm", out_dir = "data/occTest/cleaned_llm")
)

for (pl in pipelines) {
  dir.create(pl$out_dir, recursive = TRUE, showWarnings = FALSE)

  csv_files <- list.files(pl$in_dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(csv_files) == 0) {
    message("No CSVs found in ", pl$in_dir, " — skipping")
    next
  }

  filterSumm <- data.frame(
    Species   = character(length(csv_files)),
    NoOccs    = integer(length(csv_files)),
    PostFilter = integer(length(csv_files)),
    Removed   = integer(length(csv_files)),
    stringsAsFactors = FALSE
  )

  for (i in seq_along(csv_files)) {
    data     <- read_csv(csv_files[i], show_col_types = FALSE)
    sp_snake <- tools::file_path_sans_ext(basename(csv_files[i]))
    sp_name  <- str_to_title(gsub("_", " ", sp_snake))
    message(pl$in_dir, " | ", sp_name, " (", nrow(data), " records)")

    coords <- data %>%
      rename(decimalLongitude = lon, decimalLatitude = lat) %>%
      select(decimalLongitude, decimalLatitude)

    occTest_result <- occTest(
      sp.name          = sp_name,
      habitat          = "terrestrial",
      sp.table         = coords,
      r.env            = envProj,
      interactiveMode  = FALSE,
      verbose          = FALSE,
      analysisSettings = customSettings$analysisSettings,
      doParallel       = FALSE
    )

    occFilter_result <- occFilter(df = occTest_result, errorAcceptance = "strict")

    n_filtered <- nrow(occFilter_result$filteredDataset)
    if (is.null(n_filtered)) n_filtered <- 0

    filterSumm[i, "Species"]    <- sp_name
    filterSumm[i, "NoOccs"]     <- nrow(data)
    filterSumm[i, "PostFilter"] <- n_filtered
    filterSumm[i, "Removed"]    <- nrow(data) - n_filtered
    message("  ", n_filtered, " records retained after strict filter")

    # Diagnostic plots (require > 1 point)
    if (n_filtered > 1) {
      plots <- plot(x = occTest_result, occFilter_list = occFilter_result, show_plot = FALSE)
      ggarrange(plots[[1]], plots[[2]], plots[[3]], plots[[4]])
      ggsave(file.path(pl$out_dir, paste0(sp_snake, ".jpg")))
    }

    # Spatial export (KML + SHP)
    if (n_filtered > 0) {
      filtered_data <- data[occFilter_result$filteredDataset$taxonobservationID, ]
      filtered_vect <- vect(filtered_data, geom = c("lon", "lat"), crs = "EPSG:4326")
      writeVector(filtered_vect,
                  file.path(pl$out_dir, paste0(sp_snake, ".kml")),
                  overwrite = TRUE)
      writeVector(filtered_vect,
                  file.path(pl$out_dir, paste0(sp_snake, ".shp")),
                  overwrite = TRUE)
    }

    # Save R objects
    save(occTest_result, occFilter_result,
         file = file.path(pl$out_dir, paste0(sp_snake, ".rda")))

    closeAllConnections()
  }

  write_csv(filterSumm, file.path(pl$out_dir, "filterSummary.csv"))
  message("Filter summary written to ", pl$out_dir, "/filterSummary.csv")
}

message("Done.")
