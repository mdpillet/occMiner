library(terra)
library(geometry)
library(ggplot2)
library(dplyr)
library(readr)
library(sf)
library(maptiles)
library(tidyterra)

dir.create("data/comparison", recursive = TRUE, showWarnings = FALSE)

species_map <- list(
  list(name = "Ariocarpus fissuratus",
       ref  = "data/reference/Ariocarpus fissuratus_envT_extF.shp",
       new  = "data/occTest/cleaned/ariocarpus_fissuratus.shp"),
  list(name = "Pilosocereus chrysostele",
       ref  = "data/reference/Pilosocereus chrysostele_envT_extF.shp",
       new  = "data/occTest/cleaned/pilosocereus_chrysostele.shp"),
  list(name = "Pilosocereus pachycladus",
       ref  = "data/reference/Pilosocereus pachycladus_envT_extF.shp",
       new  = "data/occTest/cleaned/pilosocereus_pachycladus.shp"),
  list(name = "Thelocactus conothelos",
       ref  = "data/reference/Thelocactus conothelos_envT_extF.shp",
       new  = "data/occTest/cleaned/thelocactus_conothelos.shp")
)

# ---- Predictor raster + PCA (cached) ----

preds <- rast("data/predictors/ase_UKESM1-0-LL_current.tif")

pca_path <- "data/comparison/PCA.rda"
if (file.exists(pca_path)) {
  message("Loading cached PCA from ", pca_path)
  load(pca_path)
} else {
  message("Fitting PCA on predictor raster...")
  set.seed(2025)
  samp <- spatSample(preds, 100000, "random", na.rm = TRUE)
  samp <- samp[complete.cases(samp), ]
  pca  <- prcomp(samp, center = TRUE, scale. = TRUE)
  save(pca, file = pca_path)
  message("  PCA saved to ", pca_path)
}

# ---- Helpers ----

mcp_area_km2 <- function(v) {
  hull <- convHull(project(v, "+proj=moll +datum=WGS84"))
  expanse(hull) / 1e6
}

niche_size <- function(v) {
  extr <- terra::extract(preds, v, ID = FALSE)
  extr <- extr[complete.cases(extr), ]
  if (nrow(extr) < 3) return(NA_real_)
  trans <- predict(pca, newdata = extr)[, 1:2]
  if (nrow(unique(trans)) < 3) return(NA_real_)
  convhulln(trans, options = "FA")$vol
}

hull_polygon_df <- function(mat, label) {
  idx <- chull(mat[, 1], mat[, 2])
  idx <- c(idx, idx[1])
  data.frame(PC1 = mat[idx, 1], PC2 = mat[idx, 2], dataset = label)
}

niche_points_df <- function(v, label) {
  extr <- terra::extract(preds, v, ID = FALSE)
  extr <- extr[complete.cases(extr), ]
  if (nrow(extr) < 1) return(NULL)
  trans <- predict(pca, newdata = extr)[, 1:2]
  data.frame(PC1 = trans[, 1], PC2 = trans[, 2], dataset = label)
}

mcp_sf <- function(v, label) {
  if (nrow(v) < 3) return(NULL)
  hull   <- convHull(project(v, "EPSG:4326"))
  sf_obj <- sf::st_as_sf(hull)
  sf_obj$dataset <- label
  sf_obj[, "dataset"]
}

# ---- Per-species comparison ----

niche_colours <- c("Reference" = "#E69F00", "New" = "#0072B2", "Combined" = "#009E73")
shape_levels  <- c("reference", "direct", "direction_only", "offset_adjusted",
                   "llm_approximate", "failed")
shape_values  <- c(reference = 17, direct = 16, direction_only = 15,
                   offset_adjusted = 18, llm_approximate = 8, failed = 4)

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

  # Combined SpatVector built from raw geometries (avoids dbf attribute mismatch)
  combined_vect <- if (has_new && n_new > 0) {
    vect(rbind(crds(ref_vect), crds(new_vect)),
         type = "points", crs = crs(ref_vect))
  } else {
    ref_vect
  }
  n_combined     <- n_ref + n_new
  n_pct_increase <- (n_combined - n_ref) / n_ref * 100
  message("  n: ref=", n_ref, "  new=", n_new,
          "  combined=", n_combined,
          "  +", round(n_pct_increase, 1), "%")

  # Range size
  range_ref      <- mcp_area_km2(ref_vect)
  range_new      <- if (has_new && n_new >= 3) mcp_area_km2(new_vect)      else NA_real_
  range_combined <- if (n_combined >= 3)        mcp_area_km2(combined_vect) else NA_real_
  range_pct_increase <- if (!is.na(range_combined))
    (range_combined - range_ref) / range_ref * 100 else NA_real_
  message("  range (km²): ref=", round(range_ref),
          "  new=", if (is.na(range_new)) "NA" else round(range_new),
          "  combined=", if (is.na(range_combined)) "NA" else round(range_combined))

  # Niche size
  ns_ref      <- niche_size(ref_vect)
  ns_new      <- if (has_new) niche_size(new_vect) else NA_real_
  ns_combined <- niche_size(combined_vect)
  niche_pct_increase <- if (!is.na(ns_combined) && !is.na(ns_ref))
    (ns_combined - ns_ref) / ns_ref * 100 else NA_real_
  message("  niche size: ref=", round(ns_ref, 4),
          "  new=", if (is.na(ns_new)) "NA" else round(ns_new, 4),
          "  combined=", if (is.na(ns_combined)) "NA" else round(ns_combined, 4))

  summary_rows[[i]] <- data.frame(
    species              = name,
    n_ref                = n_ref,
    n_new                = n_new,
    n_combined           = n_combined,
    n_pct_increase       = n_pct_increase,
    range_ref_km2        = range_ref,
    range_new_km2        = range_new,
    range_combined_km2   = range_combined,
    range_pct_increase   = range_pct_increase,
    niche_ref            = ns_ref,
    niche_new            = ns_new,
    niche_combined       = ns_combined,
    niche_pct_increase   = niche_pct_increase
  )

  # ---- Niche space plot (PC1 vs PC2) ----

  if (!has_new) next

  pts_ref <- niche_points_df(ref_vect, "Reference")
  pts_new <- niche_points_df(new_vect, "New")
  if (is.null(pts_ref) || is.null(pts_new)) next

  pts <- bind_rows(pts_ref, pts_new)

  hull_ref      <- if (nrow(pts_ref) >= 3) hull_polygon_df(as.matrix(pts_ref[, 1:2]), "Reference") else NULL
  hull_new      <- if (nrow(pts_new) >= 3) hull_polygon_df(as.matrix(pts_new[, 1:2]), "New")       else NULL
  hull_combined <- if (nrow(pts) >= 3)     hull_polygon_df(as.matrix(pts[, 1:2]),     "Combined")  else NULL

  # Draw Combined hull first (behind), then Reference and New on top.
  hulls_back  <- hull_combined
  hulls_front <- bind_rows(hull_ref, hull_new)

  p <- ggplot() +
    {if (!is.null(hulls_back)) geom_polygon(data = hulls_back,
                                            aes(x = PC1, y = PC2, fill = dataset),
                                            alpha = 0.08, colour = NA)} +
    geom_polygon(data = hulls_front, aes(x = PC1, y = PC2, fill = dataset),
                 alpha = 0.18, colour = NA) +
    geom_point(data = pts, aes(x = PC1, y = PC2, colour = dataset),
               alpha = 0.6, size = 1.2) +
    scale_colour_manual(values = niche_colours, breaks = c("Reference", "New")) +
    scale_fill_manual(values = niche_colours,
                      breaks = c("Reference", "New", "Combined")) +
    labs(title = name, x = "PC1", y = "PC2", colour = NULL, fill = NULL) +
    theme_bw(base_size = 11) +
    theme(legend.position = "bottom")

  plot_path <- file.path("data/comparison", paste0(snake, ".png"))
  ggsave(plot_path, p, width = 6, height = 5, dpi = 150)
  message("  Niche plot saved to ", plot_path)

  # ---- Terrain map plot ----

  ref_pts <- sf::st_as_sf(project(ref_vect, "EPSG:4326"))
  ref_pts$source       <- "Reference"
  ref_pts$geocode_type <- "reference"

  new_pts <- sf::st_as_sf(project(new_vect, "EPSG:4326"))
  gt_col  <- intersect(c("geocode_type", "geocode_ty"), names(new_pts))[1]
  new_pts$source       <- "New"
  new_pts$geocode_type <- if (!is.na(gt_col)) new_pts[[gt_col]] else NA_character_

  pts_sf <- bind_rows(
    ref_pts[, c("source", "geocode_type")],
    new_pts[, c("source", "geocode_type")]
  )

  bb <- sf::st_bbox(pts_sf)
  dx <- as.numeric(bb["xmax"] - bb["xmin"]) * 0.10
  dy <- as.numeric(bb["ymax"] - bb["ymin"]) * 0.10
  ext_sf <- sf::st_as_sfc(
    sf::st_bbox(c(xmin = as.numeric(bb["xmin"]) - dx,
                  ymin = as.numeric(bb["ymin"]) - dy,
                  xmax = as.numeric(bb["xmax"]) + dx,
                  ymax = as.numeric(bb["ymax"]) + dy),
                crs = sf::st_crs(pts_sf))
  )

  tiles <- maptiles::get_tiles(
    x        = ext_sf,
    provider = "OpenTopoMap",
    crop     = TRUE,
    cachedir = tempdir()
  )

  mcps <- bind_rows(
    mcp_sf(ref_vect, "Reference"),
    if (has_new && n_new >= 3) mcp_sf(new_vect, "New") else NULL,
    if (n_combined >= 3)       mcp_sf(combined_vect, "Combined") else NULL
  )

  p_map <- ggplot() +
    tidyterra::geom_spatraster_rgb(data = tiles, maxcell = Inf) +
    geom_sf(data = mcps,
            aes(colour = dataset, fill = dataset),
            alpha = 0.10, linewidth = 0.6) +
    geom_sf(data = pts_sf,
            aes(colour = source, shape = geocode_type),
            size = 1.8, stroke = 0.6) +
    scale_colour_manual(values = niche_colours,
                        breaks = c("Reference", "New", "Combined")) +
    scale_fill_manual(values = niche_colours,
                      breaks = c("Reference", "New", "Combined")) +
    scale_shape_manual(values = shape_values, limits = shape_levels,
                       na.value = 4) +
    labs(title = name, colour = NULL, fill = NULL, shape = "geocode type") +
    coord_sf(crs = sf::st_crs(3857)) +
    theme_bw(base_size = 11) +
    theme(legend.position = "bottom", legend.box = "vertical")

  map_path <- file.path("data/comparison", paste0(snake, "_map.png"))
  ggsave(map_path, p_map, width = 7, height = 7, dpi = 150)
  message("  Map saved to ", map_path)
}

# ---- Summary CSV ----

summary_df <- bind_rows(summary_rows)
write_csv(summary_df, "data/comparison/summary.csv")
message("\nSummary written to data/comparison/summary.csv")
message("Done.")
