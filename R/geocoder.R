library(tidygeocoder)
library(dplyr)
library(readr)
library(stringr)
library(purrr)

species <- c(
  "Ariocarpus fissuratus",
  "Pilosocereus chrysostele",
  "Pilosocereus pachycladus",
  "Thelocactus conothelos"
)

sources  <- list(bcss = "data/bcss", clcactus = "data/clcactus")
out_dir  <- "data/geocoded"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

bearing_map <- c(N = 0, NE = 45, E = 90, SE = 135,
                 S = 180, SW = 225, W = 270, NW = 315)

# ---- Cleaning helpers ----

normalize_country <- function(x) {
  str_replace_all(x, "Mexic[oó]", "Mexico")
}

strip_elevation <- function(x) {
  str_remove_all(x, "\\b\\d+(?:[.,]\\d+)?(?:-\\d+)?\\s*m(?:asl)?\\b")
}

# Canonicalise a direction word to a 1-2 letter cardinal code.
canon_direction <- function(d) {
  d <- toupper(str_replace_all(d, "[-\\s]", ""))
  d <- str_replace_all(d, c("NORTH" = "N", "SOUTH" = "S", "EAST" = "E", "WEST" = "W"))
  d
}

# Returns list(distance_km, direction, base_place) or NULL.
parse_offset <- function(x) {
  m <- str_match(
    x,
    regex(
      paste0(
        "^(?:(\\d+(?:[.,]\\d+)?)\\s*(?:km|mi|m)\\s+)?",
        "(N|S|E|W|NE|NW|SE|SW|North(?:-?East|-?West)?|South(?:-?East|-?West)?|East|West)",
        "(?:-?of|\\s+of)\\s+(.+)$"
      ),
      ignore_case = TRUE
    )
  )
  if (is.na(m[1, 1])) return(NULL)
  list(
    distance_km = if (is.na(m[1, 2])) NA_real_
                  else as.numeric(str_replace(m[1, 2], ",", ".")),
    direction   = canon_direction(m[1, 3]),
    base_place  = trimws(m[1, 4])
  )
}

# Returns "locality, State, Country" string or NULL.
parse_colon_format <- function(x) {
  m <- str_match(x, "^([^:]+)\\s*:\\s*([^(]+?)(?:\\s*\\(([^)]+)\\))?\\s*$")
  if (is.na(m[1, 1])) return(NULL)
  country  <- trimws(m[1, 2])
  state    <- trimws(m[1, 3])
  detail   <- if (is.na(m[1, 4])) NA_character_ else trimws(m[1, 4])
  parts    <- c(detail, state, country)
  paste(parts[!is.na(parts) & nchar(parts) > 0], collapse = ", ")
}

# Returns list(query, offset_info) where offset_info is NULL or from parse_offset.
build_query <- function(raw) {
  if (is.na(raw) || nchar(trimws(raw)) == 0) {
    return(list(query = NA_character_, offset_info = NULL))
  }
  x <- normalize_country(raw)
  x <- strip_elevation(x)
  x <- trimws(x)

  offset <- parse_offset(x)
  if (!is.null(offset)) {
    return(list(query = offset$base_place, offset_info = offset))
  }

  colon <- parse_colon_format(x)
  if (!is.null(colon)) {
    return(list(query = colon, offset_info = NULL))
  }

  list(query = x, offset_info = NULL)
}

# Spherical offset: returns list(lat, lon).
apply_offset <- function(lat, lon, distance_km, bearing_deg) {
  if (any(is.na(c(lat, lon, distance_km, bearing_deg)))) {
    return(list(lat = lat, lon = lon))
  }
  d    <- distance_km / 6371
  b    <- bearing_deg * pi / 180
  r    <- lat * pi / 180
  lat2 <- asin(sin(r) * cos(d) + cos(r) * sin(d) * cos(b))
  lon2 <- lon * pi / 180 +
    atan2(sin(b) * sin(d) * cos(r), cos(d) - sin(r) * sin(lat2))
  list(lat = lat2 * 180 / pi, lon = lon2 * 180 / pi)
}

# ---- Per-species processing ----

for (sp in species) {
  message("Geocoding: ", sp)
  filename <- paste0(gsub(" ", "_", tolower(sp)), ".csv")

  parts <- map(names(sources), function(src) {
    path <- file.path(sources[[src]], filename)
    if (!file.exists(path)) return(NULL)
    df <- read_csv(path, show_col_types = FALSE)
    if (nrow(df) == 0) return(NULL)
    mutate(df, source = src)
  })
  combined <- bind_rows(compact(parts))

  if (nrow(combined) == 0) {
    message("  No records — skipping")
    next
  }

  # Build query info for every row
  query_info <- map(combined$locality, build_query)
  combined <- combined %>%
    mutate(
      geocode_query = map_chr(query_info, "query"),
      geocode_type  = "direct"
    )

  # Batch geocode unique non-NA queries
  unique_q <- tibble(geocode_query = unique(na.omit(combined$geocode_query)))

  if (nrow(unique_q) > 0) {
    coords <- geocode(unique_q, geocode_query,
                      method = "osm", lat = "lat", long = "lon")

    failed <- filter(coords, is.na(lat))
    if (nrow(failed) > 0) {
      message("  ", nrow(failed), " query/queries failed OSM — trying ArcGIS")
      fb     <- geocode(select(failed, geocode_query), geocode_query,
                        method = "arcgis", lat = "lat", long = "lon")
      coords <- bind_rows(filter(coords, !is.na(lat)), fb)
    }

    combined <- left_join(combined, coords, by = "geocode_query")

    # Apply bearing offsets row by row
    for (i in seq_len(nrow(combined))) {
      oi <- query_info[[i]]$offset_info
      if (is.null(oi)) next
      if (is.na(combined$lat[i])) {
        combined$geocode_type[i] <- "failed"
        next
      }
      bearing <- bearing_map[oi$direction]
      if (is.na(bearing) || is.na(oi$distance_km)) {
        combined$geocode_type[i] <- "direction_only"
        next
      }
      new_coords <- apply_offset(combined$lat[i], combined$lon[i],
                                 oi$distance_km, bearing)
      combined$lat[i]          <- new_coords$lat
      combined$lon[i]          <- new_coords$lon
      combined$geocode_type[i] <- "offset_adjusted"
    }
  } else {
    combined <- mutate(combined, lat = NA_real_, lon = NA_real_)
  }

  # Mark rows with NA query or NA coords as failed
  combined <- combined %>%
    mutate(
      geocode_type = case_when(
        is.na(geocode_query)                    ~ "failed",
        geocode_type == "direct" & is.na(lat)  ~ "failed",
        TRUE                                    ~ geocode_type
      )
    )

  outpath <- file.path(out_dir, filename)
  write_csv(combined, outpath)
  message("  Written ", nrow(combined), " records to ", outpath)
}

message("Done. CSVs written to ", out_dir, "/")
