run <- function(script) {
  message("\n==> ", script)
  source(script)
}

# Remove all pipeline output from previous runs (Logs/ is preserved)
message("Cleaning previous output...")
unlink(c("data/bcss", "data/clcactus",
         "data/geocoded", "data/geocoded_llm",
         "data/cleaned", "data/cleaned_llm",
         "data/kml", "data/shp",
         "data/occTest",
         "Logs"),
       recursive = TRUE)

run("R/bcss_miner.R")
run("R/clcactus_miner.R")
run("R/geocoder.R")
run("R/geocoder_llm.R")
run("R/coordinateCleaner.R")
run("R/mapCreator.R")
run("R/occTest.R")

message("\nPipeline complete.")
