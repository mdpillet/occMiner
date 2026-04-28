library(terra)
library(occTest)
library(ggpubr)

# Set paths
occPath <- "D:/Research/DroughtForecasts/Data/Occurrences/BySpecies/Over10/"
envRaster <- "D:/Research/DroughtForecasts/Data/Predictors/ase_UKESM1-0-LL_SSP585.tif"
outPath <- "D:/Research/DroughtForecasts/Data/Occurrences/BySpecies/Filtered/" 

# Read occurrence data
species <- list.files(occPath, "shp$", full.names = T)

# Read environmental raster
env <- rast(envRaster)
envProj <- project(env, crs(vect(species[1])))
envProj_all <- envProj
envProj_noExt <- envProj[[1:26]]

# Set occTest settings
customSettings <- defaultSettings()
customSettings$analysisSettings$filterAtlas <- F

# Filter summary
filterSumm <- data.frame(Species = character(length(species)),
                         NoOccs = integer(length(species)),
                         PostFilter_envT_extT = integer(length(species)),
                         PostFilter_envF_extF = integer(length(species)),
                         PostFilter_envT_extF = integer(length(species)),
                         AddlRemovedEnv_extT = integer(length(species)),
                         AddlRemovedEnv_extF = integer(length(species)))

# Loop over species
for (i in 1:length(species)) {
  # Load and count occurrences, print name
  occ <- vect(species[i])
  filterSumm[i, "NoOccs"] <- nrow(occ)
  print(unique(occ$FinalSpeci))
  filterSumm[i, "Species"] <- unique(occ$FinalSpeci)
  
  # Get coordinates
  coords <- as.data.frame(crds(occ))
  names(coords) <- c("decimalLongitude", "decimalLatitude")
  
  # Perform tests
  occTest_envT_extT <- occTest(sp.name = unique(occ$FinalSpeci),
                         habitat = "terrestrial",
                         sp.table = coords,
                         r.env = envProj_all, 
                         interactiveMode = F,
                         verbose = F,
                         analysisSettings = customSettings$analysisSettings,
                         doParallel = F)
  occTest_envT_extF <- occTest(sp.name = unique(occ$FinalSpeci),
                           habitat = "terrestrial",
                           sp.table = coords,
                           r.env = envProj_noExt, 
                           interactiveMode = F,
                           verbose = F,
                           analysisSettings = customSettings$analysisSettings,
                           doParallel = F)
  customSettings$analysisSettings$envOutliers$doEnvOutliers <- F
  occTest_envF_extF <- occTest(sp.name = unique(occ$FinalSpeci),
                               habitat = "terrestrial",
                               sp.table = coords,
                               r.env = envProj_noExt, 
                               interactiveMode = F,
                               verbose = F,
                               analysisSettings = customSettings$analysisSettings,
                               doParallel = F)
  customSettings$analysisSettings$envOutliers$doEnvOutliers <- T
  
  # Filter occurrences
  occFilter_envT_extT <- occFilter(df = occTest_envT_extT, errorAcceptance = "strict")
  occFilter_envT_extF <- occFilter(df = occTest_envT_extF, errorAcceptance = "strict")
  occFilter_envF_extF <- occFilter(df = occTest_envF_extF, errorAcceptance = "strict")
  n_envT_extT <- nrow(occFilter_envT_extT$filteredDataset)
  if (is.null(n_envT_extT)) n_envT_extT <- 0
  n_envT_extF <- nrow(occFilter_envT_extF$filteredDataset)
  if (is.null(n_envT_extF)) n_envT_extF <- 0
  n_envF_extF <- nrow(occFilter_envF_extF$filteredDataset)
  if (is.null(n_envF_extF)) n_envF_extF <- 0
  filterSumm[i, "PostFilter_envT_extT"] <- n_envT_extT
  filterSumm[i, "PostFilter_envT_extF"] <- n_envT_extF
  filterSumm[i, "PostFilter_envF_extF"] <- n_envF_extF
  filterSumm[i, "AddlRemovedEnv_extT"] <- filterSumm[i, "PostFilter_envF_extF"] - filterSumm[i, "PostFilter_envT_extT"]
  filterSumm[i, "AddlRemovedEnv_extF"] <- filterSumm[i, "PostFilter_envF_extF"] - filterSumm[i, "PostFilter_envT_extF"]
  
  # Set output folder
  if (min(n_envF_extF, n_envT_extF, n_envT_extT) >= 10) {
    outFolder <- "Over10/"
  } else outFolder <- "Other/"
  
  # Plot results
  if (min(n_envF_extF, n_envT_extF, n_envT_extT) > 1) {
    plot_envT_extT <- plot(x = occTest_envT_extT, occFilter_list = occFilter_envT_extT, show_plot = F)
    plot_envT_extF <- plot(x = occTest_envT_extF, occFilter_list = occFilter_envT_extF, show_plot = F)
    plot_envF_extF <- plot(x = occTest_envF_extF, occFilter_list = occFilter_envF_extF, show_plot = F)
    ggarrange(plot_envT_extT[[1]], plot_envT_extT[[2]], plot_envT_extT[[3]], plot_envT_extT[[4]])
    ggsave(paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extT.jpg"))
    ggarrange(plot_envT_extF[[1]], plot_envT_extF[[2]], plot_envT_extF[[3]], plot_envT_extF[[4]])
    ggsave(paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extF.jpg"))
    ggarrange(plot_envF_extF[[1]], plot_envF_extF[[2]], plot_envF_extF[[3]], plot_envF_extF[[4]])
    ggsave(paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envF_extF.jpg"))  
  }
  
  # Export filtered occurrences
  if (n_envT_extT > 0) {
    writeVector(occ[occFilter_envT_extT$filteredDataset$taxonobservationID], paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extT.kml"), overwrite = T)
    writeVector(occ[occFilter_envT_extT$filteredDataset$taxonobservationID], paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extT.shp"), overwrite = T)  
  }
  if (n_envT_extF > 0) {
    writeVector(occ[occFilter_envT_extF$filteredDataset$taxonobservationID], paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extF.kml"), overwrite = T)
    writeVector(occ[occFilter_envT_extF$filteredDataset$taxonobservationID], paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extF.shp"), overwrite = T)  
  }
  if (n_envF_extF > 0) {
    writeVector(occ[occFilter_envF_extF$filteredDataset$taxonobservationID], paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envF_extF.kml"), overwrite = T)
    writeVector(occ[occFilter_envF_extF$filteredDataset$taxonobservationID], paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envF_extF.shp"), overwrite = T)  
  }
  
  # Save objects
  save(occTest_envT_extT, occFilter_envT_extT, file = paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extT.rda"))
  save(occTest_envT_extF, occFilter_envT_extF, file = paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envT_extF.rda"))
  save(occTest_envF_extF, occFilter_envF_extF, file = paste0(outPath, outFolder, unique(occ$FinalSpeci), "_envF_extF.rda"))
  
  # Print summary and clean up
  closeAllConnections()
  print(filterSumm[i,])
}
filterSumm$FractionRemoved <- filterSumm$AddlRemovedEnv_extF / filterSumm$PostFilter_envF_extF

# Export summary
write.csv(filterSumm, paste0(outPath, "filterSummary.csv"), row.names = F)