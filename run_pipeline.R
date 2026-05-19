run <- function(script) {
  message("\n==> ", script)
  source(script)
}

# Remove all pipeline output from previous runs. Expensive caches are preserved:
#   data/comparison/PCA.rda           — random-sample PCA fit
#   data/cooccurrence_llm/.cache.csv  — per-notes Gemini extraction results
message("Cleaning previous output...")
unlink(c("data/bcss", "data/clcactus", "data/combined",
         "data/geocoded", "data/geocoded_llm",
         "data/cleaned", "data/cleaned_llm",
         "data/kml", "data/shp",
         "data/occTest",
         "Logs"),
       recursive = TRUE)
if (dir.exists("data/comparison")) {
  comp_files <- list.files("data/comparison", full.names = TRUE, recursive = TRUE)
  unlink(comp_files[basename(comp_files) != "PCA.rda"])
}
if (dir.exists("data/cooccurrence_llm")) {
  cc_files <- list.files("data/cooccurrence_llm", full.names = TRUE, recursive = TRUE)
  unlink(cc_files[basename(cc_files) != ".cache.csv"])
}

run("R/bcss_miner.R")
run("R/clcactus_miner.R")
run("R/combineOccs.R")
run("R/cooccurrence_llm.R")
run("R/geocoder.R")
run("R/geocoder_llm.R")
run("R/coordinateCleaner.R")
run("R/mapCreator.R")
run("R/occTest.R")

if (dir.exists("data/reference")) {
  run("R/compareOccurrences.R")
} else {
  message("\nSkipping R/compareOccurrences.R — data/reference/ not present")
}

message("\nPipeline complete.")