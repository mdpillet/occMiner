library(terra)
library(geometry)
library(ggplot2)
library(dplyr)
library(readr)

dir.create("data/comparison", recursive = TRUE, showWarnings = FALSE)

species_map <- list(
  list(name = "Ariocarpus fissuratus",
       ref  = "data/reference/Ariocarpus fissuratus_envT_extF_thin0.shp",
       new  = "data/occTest/cleaned/ariocarpus_fissuratus.shp"),
  list(name = "Pilosocereus chrysostele",
       ref  = "data/reference/Pilosocereus chrysostele_envT_extF_thin0.shp",
       new  = "data/occTest/cleaned/pilosocereus_chrysostele.shp"),
  list(name = "Pilosocereus pachycladus",
       ref  = "data/reference/Pilosocereus pachycladus_envT_extF_thin0.shp",
       new  = "data/occTest/cleaned/pilosocereus_pachycladus.shp"),
  list(name = "Thelocactus conothelos",
       ref  = "data/reference/Thelocactus conothelos_envT_extF_thin0.shp",
       new  = "data/occTest/cleaned/thelocactus_conothelos.shp")
)

# ---- PCA on full predictor raster ----

message("Fitting PCA on predictor raster...")
preds <- rast("data/predictors/ase_UKESM1-0-LL_current.tif")
set.seed(2025)
samp <- spatSample(preds, 100000, "random", na.rm = TRUE)
samp <- samp[complete.cases(samp), ]
pca  <- prcomp(samp, center = TRUE, scale. = TRUE)
save(pca, file = "data/comparison/PCA.rda")
message("  PCA saved to data/comparison/PCA.rda")

# ---- Helpers ----

mcp_area_km2 <- function(vect) {
  hull <- convHull(project(vect, "+proj=moll +datum=WGS84"))
  expanse(hull) / 1e6
}

niche_size <- function(vect) {
  extr <- terra::extract(preds, vect, ID = FALSE)
  extr <- extr[complete.cases(extr), ]
  if (nrow(extr) < 3) return(NA_real_)
  trans <- predict(pca, newdata = extr)[, 1:2]
  if (nrow(unique(trans)) < 3) return(NA_real_)
  convhulln(trans, options = "FA")$vol
}

hull_polygon_df <- function(mat, label) {
  idx    <- chull(mat[, 1], mat[, 2])
  idx    <- c(idx, idx[1])
  data.frame(PC1 = mat[idx, 1], PC2 = mat[idx, 2], dataset = label)
}

niche_points_df <- function(vect, label) {
  extr <- terra::extract(preds, vect, ID = FALSE)
  extr <- extr[complete.cases(extr), ]
  if (nrow(extr) < 1) return(NULL)
  trans <- predict(pca, newdata = extr)[, 1:2]
  data.frame(PC1 = trans[, 1], PC2 = trans[, 2], dataset = label)
}

# ---- Per-species comparison ----

summary_rows <- vector("list", length(species_map))

for (i in seq_along(species_map)) {
  sp    <- species_map[[i]]
  name  <- sp$name
  snake <- gsub(" ", "_", tolower(name))
  message("\nProcessing: ", name)

  ref_vect <- vect(sp$ref)
  n_ref    <- nrow(ref_vect)

  has_new <- file.exists(sp$new)
  if (has_new) {
    new_vect <- vect(sp$new)
    n_new    <- nrow(new_vect)
  } else {
    message("  New shapefile not found — recording NA")
    n_new <- 0L
  }

  # Occurrence count
  n_diff <- n_new - n_ref
  message("  n: ref=", n_ref, "  new=", n_new, "  diff=", n_diff)

  # Range size
  range_ref <- mcp_area_km2(ref_vect)
  range_new <- if (has_new && n_new >= 3) mcp_area_km2(new_vect) else NA_real_
  range_diff <- if (!is.na(range_new)) range_new - range_ref else NA_real_
  message("  range (km²): ref=", round(range_ref), "  new=",
          if (is.na(range_new)) "NA" else round(range_new))

  # Niche size
  ns_ref  <- niche_size(ref_vect)
  ns_new  <- if (has_new) niche_size(new_vect) else NA_real_
  ns_diff <- if (!is.na(ns_new) && !is.na(ns_ref)) ns_new - ns_ref else NA_real_
  message("  niche size: ref=", round(ns_ref, 4), "  new=",
          if (is.na(ns_new)) "NA" else round(ns_new, 4))

  summary_rows[[i]] <- data.frame(
    species        = name,
    n_ref          = n_ref,
    n_new          = n_new,
    n_diff         = n_diff,
    range_ref_km2  = range_ref,
    range_new_km2  = range_new,
    range_diff_km2 = range_diff,
    niche_ref      = ns_ref,
    niche_new      = ns_new,
    niche_diff     = ns_diff
  )

  # Niche space plot
  if (!has_new) next

  pts_ref <- niche_points_df(ref_vect, "Reference")
  pts_new <- niche_points_df(new_vect, "New")
  if (is.null(pts_ref) || is.null(pts_new)) next

  pts <- bind_rows(pts_ref, pts_new)

  hull_ref <- if (nrow(pts_ref) >= 3) hull_polygon_df(as.matrix(pts_ref[, 1:2]), "Reference") else NULL
  hull_new <- if (nrow(pts_new) >= 3) hull_polygon_df(as.matrix(pts_new[, 1:2]), "New")       else NULL
  hulls    <- bind_rows(hull_ref, hull_new)

  colours <- c("Reference" = "#E69F00", "New" = "#0072B2")

  p <- ggplot(pts, aes(x = PC1, y = PC2, colour = dataset)) +
    geom_point(alpha = 0.6, size = 1.2) +
    geom_polygon(data = hulls, aes(fill = dataset), alpha = 0.12, colour = NA) +
    scale_colour_manual(values = colours) +
    scale_fill_manual(values = colours) +
    labs(title = name, x = "PC1", y = "PC2", colour = NULL, fill = NULL) +
    theme_bw(base_size = 11) +
    theme(legend.position = "bottom")

  plot_path <- file.path("data/comparison", paste0(snake, ".png"))
  ggsave(plot_path, p, width = 6, height = 5, dpi = 150)
  message("  Plot saved to ", plot_path)
}

# ---- Summary CSV ----

summary_df <- bind_rows(summary_rows)
write_csv(summary_df, "data/comparison/summary.csv")
message("\nSummary written to data/comparison/summary.csv")
message("Done.")
