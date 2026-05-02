library(terra)
library(geometry)
library(ggplot2)
library(dplyr)
library(readr)
library(sf)
library(maptiles)
library(tidyterra)
library(ggpubr)

dir.create("data/comparison", recursive = TRUE, showWarnings = FALSE)

species_list <- list(
  list(name = "Ariocarpus fissuratus",
       ref  = "data/reference/Ariocarpus fissuratus_envT_extF.shp",
       slug = "ariocarpus_fissuratus"),
  list(name = "Pilosocereus pachycladus",
       ref  = "data/reference/Pilosocereus pachycladus_envT_extF.shp",
       slug = "pilosocereus_pachycladus"),
  list(name = "Thelocactus conothelos",
       ref  = "data/reference/Thelocactus conothelos_envT_extF.shp",
       slug = "thelocactus_conothelos"),
  list(name = "Trichocereus macrogonus",
       ref  = "data/reference/Trichocereus macrogonus_envT_extF.shp",
       slug = "trichocereus_macrogonus"),
  list(name = "Eulychnia taltalensis",
       ref  = "data/reference/Eulychnia taltalensis_envT_extF.shp",
       slug = "eulychnia_taltalensis"),
  list(name = "Epithelantha pachyrhiza",
       ref  = "data/reference/Epithelantha pachyrhiza_envT_extF.shp",
       slug = "epithelantha_pachyrhiza"),
  list(name = "Stephanocereus luetzelburgii",
       ref  = "data/reference/Stephanocereus luetzelburgii_envT_extF.shp",
       slug = "stephanocereus_luetzelburgii"),
  list(name = "Astrophytum myriostigma",
       ref  = "data/reference/Astrophytum myriostigma_envT_extF.shp",
       slug = "astrophytum_myriostigma"),
  list(name = "Melocactus salvadorensis",
       ref  = "data/reference/Melocactus salvadorensis_envT_extF.shp",
       slug = "melocactus_salvadorensis"),
  list(name = "Eriosyce wagenknechtii",
       ref  = "data/reference/Eriosyce wagenknechtii_envT_extF.shp",
       slug = "eriosyce_wagenknechtii"),
  list(name = "Rhipsalis hileiabaiana",
       ref  = "data/reference/Rhipsalis hileiabaiana_envT_extF.shp",
       slug = "rhipsalis_hileiabaiana"),
  list(name = "Opuntia mesacantha",
       ref  = "data/reference/Opuntia mesacantha_envT_extF.shp",
       slug = "opuntia_mesacantha")
)

pipelines <- list(
  list(id = "cleaned_llm", label = "LLM pipeline (cleaned_llm)",
       dir = "data/occTest/cleaned_llm"),
  list(id = "cleaned",     label = "Regex pipeline (cleaned)",
       dir = "data/occTest/cleaned")
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
  trans <- predict(pca, newdata = extr)[, 1:2, drop = FALSE]
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
  trans <- predict(pca, newdata = extr)[, 1:2, drop = FALSE]
  data.frame(PC1 = trans[, 1], PC2 = trans[, 2], dataset = label)
}

mcp_sf <- function(v, label) {
  if (nrow(v) < 3) return(NULL)
  hull   <- convHull(project(v, "EPSG:4326"))
  sf_obj <- sf::st_as_sf(hull)
  sf_obj$dataset <- label
  sf_obj[, "dataset"]
}

empty_panel <- function(msg = "No data") {
  ggplot() +
    annotate("text", x = 0, y = 0, label = msg, size = 4, colour = "grey40") +
    theme_void()
}

fmt_int   <- function(x) if (is.na(x)) "—" else format(round(x), big.mark = ",")
fmt_niche <- function(x) if (is.na(x)) "—" else format(round(x, 3), nsmall = 3)
fmt_pct   <- function(x) if (is.na(x)) "—" else paste0(if (x >= 0) "+" else "",
                                                            format(round(x, 1), nsmall = 1), "%")

stats_table <- function(row) {
  m <- matrix(c(
    fmt_int(row$n_ref),         fmt_int(row$n_new),         fmt_int(row$n_combined),         fmt_pct(row$n_pct_increase),
    fmt_int(row$range_ref_km2), fmt_int(row$range_new_km2), fmt_int(row$range_combined_km2), fmt_pct(row$range_pct_increase),
    fmt_niche(row$niche_ref),   fmt_niche(row$niche_new),   fmt_niche(row$niche_combined),   fmt_pct(row$niche_pct_increase)
  ), nrow = 3, byrow = TRUE,
     dimnames = list(c("n", "range (km²)", "niche (PCA)"),
                     c("Reference", "New", "Combined", "+%")))
  ggpubr::ggtexttable(m, theme = ggpubr::ttheme("light", base_size = 9))
}

# ---- Per-(species x pipeline) worker ----

niche_colours <- c("Reference" = "#E69F00", "New" = "#0072B2", "Combined" = "#009E73")
shape_levels  <- c("reference", "direct", "direction_only", "offset_adjusted",
                   "llm_approximate", "failed")
shape_values  <- c(reference = 17, direct = 16, direction_only = 15,
                   offset_adjusted = 18, llm_approximate = 8, failed = 4)

compare_one <- function(species, pipeline, ref_vect) {
  name     <- species$name
  slug     <- species$slug
  new_path <- file.path(pipeline$dir, paste0(slug, ".shp"))
  message("  [", pipeline$id, "] ", name)

  n_ref <- nrow(ref_vect)

  has_new <- file.exists(new_path)
  if (has_new) {
    new_vect <- vect(new_path)
    n_new    <- nrow(new_vect)
  } else {
    message("    New shapefile not found at ", new_path)
    new_vect <- NULL
    n_new    <- 0L
  }

  combined_vect <- if (has_new && n_new > 0) {
    vect(rbind(crds(ref_vect), crds(new_vect)),
         type = "points", crs = crs(ref_vect))
  } else {
    ref_vect
  }
  n_combined     <- n_ref + n_new
  n_pct_increase <- (n_combined - n_ref) / n_ref * 100

  range_ref      <- mcp_area_km2(ref_vect)
  range_new      <- if (has_new && n_new >= 3) mcp_area_km2(new_vect)      else NA_real_
  range_combined <- if (n_combined >= 3)        mcp_area_km2(combined_vect) else NA_real_
  range_pct_increase <- if (!is.na(range_combined))
    (range_combined - range_ref) / range_ref * 100 else NA_real_

  ns_ref      <- niche_size(ref_vect)
  ns_new      <- if (has_new) niche_size(new_vect) else NA_real_
  ns_combined <- niche_size(combined_vect)
  niche_pct_increase <- if (!is.na(ns_combined) && !is.na(ns_ref))
    (ns_combined - ns_ref) / ns_ref * 100 else NA_real_

  message("    n: ref=", n_ref, " new=", n_new, " combined=", n_combined,
          " (+", round(n_pct_increase, 1), "%)")
  message("    range km²: ref=", round(range_ref),
          " new=", if (is.na(range_new)) "NA" else round(range_new),
          " combined=", if (is.na(range_combined)) "NA" else round(range_combined))
  message("    niche: ref=", round(ns_ref, 4),
          " new=", if (is.na(ns_new)) "NA" else round(ns_new, 4),
          " combined=", if (is.na(ns_combined)) "NA" else round(ns_combined, 4))

  summary_row <- data.frame(
    species              = name,
    pipeline             = pipeline$id,
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

  niche_plot <- NULL
  map_plot   <- NULL

  if (has_new && n_new > 0) {
    pts_ref <- niche_points_df(ref_vect, "Reference")
    pts_new <- niche_points_df(new_vect, "New")

    if (!is.null(pts_ref) && !is.null(pts_new)) {
      pts <- bind_rows(pts_ref, pts_new)

      hull_ref      <- if (nrow(pts_ref) >= 3) hull_polygon_df(as.matrix(pts_ref[, 1:2]), "Reference") else NULL
      hull_new      <- if (nrow(pts_new) >= 3) hull_polygon_df(as.matrix(pts_new[, 1:2]), "New")       else NULL
      hull_combined <- if (nrow(pts) >= 3)     hull_polygon_df(as.matrix(pts[, 1:2]),     "Combined")  else NULL

      hulls_back  <- hull_combined
      hulls_front <- bind_rows(hull_ref, hull_new)

      niche_plot <- ggplot() +
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
        labs(x = "PC1", y = "PC2", colour = NULL, fill = NULL) +
        theme_bw(base_size = 11) +
        theme(legend.position    = "bottom",
              legend.text        = element_text(size = 7),
              legend.key.size    = unit(0.35, "cm"),
              legend.margin      = margin(0, 0, 0, 0),
              legend.box.spacing = unit(2, "pt"))
    }

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

    map_plot <- ggplot() +
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
      labs(colour = NULL, fill = NULL, shape = "geocode type") +
      coord_sf(crs = sf::st_crs(3857)) +
      theme_bw(base_size = 11) +
      theme(legend.position    = "bottom",
            legend.box         = "vertical",
            legend.text        = element_text(size = 7),
            legend.title       = element_text(size = 8),
            legend.key.size    = unit(0.35, "cm"),
            legend.margin      = margin(0, 0, 0, 0),
            legend.box.spacing = unit(2, "pt"))
  }

  list(
    summary_row      = summary_row,
    niche_plot       = niche_plot,
    map_plot         = map_plot,
    stats_table_grob = stats_table(summary_row)
  )
}

# ---- PDF assembly ----

build_species_pdf <- function(path, title, top, bottom) {
  row_for <- function(r, lab) {
    pair <- ggpubr::ggarrange(
      if (is.null(r$map_plot))   empty_panel("No map data")   else r$map_plot,
      if (is.null(r$niche_plot)) empty_panel("No niche data") else r$niche_plot,
      ncol = 2, widths = c(1, 1)
    )
    block <- ggpubr::ggarrange(
      pair, r$stats_table_grob,
      ncol = 1, heights = c(3, 1)
    )
    ggpubr::annotate_figure(
      block,
      top = ggpubr::text_grob(lab, face = "bold", size = 12)
    )
  }

  page <- ggpubr::ggarrange(
    row_for(top,    "LLM pipeline (cleaned_llm)"),
    row_for(bottom, "Regex pipeline (cleaned)"),
    ncol = 1, heights = c(1, 1)
  )
  page <- ggpubr::annotate_figure(
    page,
    top = ggpubr::text_grob(title, face = "italic", size = 14)
  )

  ggsave(path, page, width = 8.5, height = 11, units = "in",
         device = cairo_pdf)
}

# ---- Main loop ----

summary_rows <- list()

for (sp in species_list) {
  message("\nProcessing: ", sp$name)
  ref_vect <- vect(sp$ref)

  results <- lapply(pipelines, function(pl) compare_one(sp, pl, ref_vect))
  names(results) <- vapply(pipelines, `[[`, "", "id")

  for (id in names(results)) {
    r <- results[[id]]
    summary_rows[[length(summary_rows) + 1L]] <- r$summary_row

    if (!is.null(r$niche_plot)) {
      ggsave(file.path("data/comparison", paste0(sp$slug, "_", id, ".png")),
             r$niche_plot, width = 6, height = 5, dpi = 150)
    }
    if (!is.null(r$map_plot)) {
      ggsave(file.path("data/comparison", paste0(sp$slug, "_", id, "_map.png")),
             r$map_plot, width = 7, height = 7, dpi = 150)
    }
  }

  pdf_path <- file.path("data/comparison", paste0(sp$slug, ".pdf"))
  build_species_pdf(pdf_path, sp$name,
                    top    = results[["cleaned_llm"]],
                    bottom = results[["cleaned"]])
  message("  PDF saved to ", pdf_path)
}

# ---- Summary CSV ----

summary_df <- bind_rows(summary_rows)
write_csv(summary_df, "data/comparison/summary.csv")
message("\nSummary written to data/comparison/summary.csv")
message("Done.")
