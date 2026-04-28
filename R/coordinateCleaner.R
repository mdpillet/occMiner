library(CoordinateCleaner)

# Set paths
relDir <- ("D:/Research/DroughtForecasts/Data/")
inPath <- "Occurrences/combined.csv"
outPath <- "Occurrences/combined_coordsCleaned.csv"

# Read occurrence data
occ <- read.csv(paste0(relDir, inPath), header = T)

# Run observations through CoordinateCleaner
flags <- clean_coordinates(occ,
                           lon = "lon",
                           lat = "lat",
                           species = "Taxon",
                           seas_scale = 50,
                           tests = c("capitals",
                                     "centroids",
                                     "equal",
                                     "gbif",
                                     "institutions",
                                     "seas",
                                     "zeros"))
occCleaned <- subset(flags, .summary == TRUE)
occCleaned <- occCleaned[, c("AccNo", "Taxon", "lat", "lon")]

# Only keep New World observations
occCoordsCleaned <- subset(occCleaned, lat <= 60 & lat >= -60 &
                lon <= -30 & lon >= -135)

# Export observations
write.csv(occCoordsCleaned, paste0(relDir, outPath), row.names = F)