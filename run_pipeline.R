run <- function(script) {
  message("\n==> ", script)
  source(script)
}

run("R/bcss_miner.R")
run("R/clcactus_miner.R")
run("R/geocoder.R")
run("R/geocoder_llm.R")
run("R/coordinateCleaner.R")
run("R/mapCreator.R")
run("R/occTest.R")

message("\nPipeline complete.")
