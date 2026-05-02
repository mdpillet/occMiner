library(httr2)
library(tidygeocoder)
library(dplyr)
library(readr)
library(stringr)
library(purrr)
library(jsonlite)

if (nchar(Sys.getenv("GEMINI_API_KEY")) == 0) {
  stop("GEMINI_API_KEY is not set. Add it to .Renviron or set with Sys.setenv().")
}

CHUNK_SIZE  <- 50
MAX_RETRIES <- 3

species <- c(
  "Ariocarpus fissuratus",
  "Pilosocereus pachycladus",
  "Thelocactus conothelos",
  "Trichocereus macrogonus",
  "Eulychnia taltalensis",
  "Epithelantha pachyrhiza",
  "Stephanocereus luetzelburgii",
  "Astrophytum myriostigma",
  "Melocactus salvadorensis",
  "Eriosyce wagenknechtii",
  "Rhipsalis hileiabaiana",
  "Opuntia mesacantha"
)

sources <- list(bcss = "data/bcss", clcactus = "data/clcactus")
out_dir <- "data/geocoded_llm"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

log_dir  <- "Logs"
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
log_path <- file.path(log_dir, paste0("geocoder_llm_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))

log_gemini <- function(label, input_json, output = NULL, error = NULL) {
  ts    <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  lines <- c(
    sprintf("=== %s | %s ===", ts, label),
    "--- INPUT ---",
    input_json,
    if (!is.null(output)) c("--- OUTPUT ---", output),
    if (!is.null(error))  c("--- ERROR ---",  error),
    "--- END ---",
    ""
  )
  cat(paste(lines, collapse = "\n"), "\n", file = log_path, append = TRUE)
}

# Copied verbatim from geocoder.R
bearing_map <- c(N = 0, NE = 45, E = 90, SE = 135,
                 S = 180, SW = 225, W = 270, NW = 315)

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

# ---- Prompt ----

PARSE_PROMPT <- paste(
  "You are a geocoding assistant for botanical collection records.",
  "You will receive a JSON array. Each element has an integer 'i' and a 'locality' string.",
  "Return ONLY a JSON array with exactly one object per input element, preserving 'i'.",
  "No prose, no markdown fences.",
  "",
  "Each output object schema:",
  "{",
  "  \"i\":            <same integer as input>,",
  "  \"address\":      \"<clean geocoder-ready string, or null if unresolvable>\",",
  "  \"offset\":       {",
  "    \"base\":        \"<place name to geocode>\",",
  "    \"distance_km\": <number or null>,",
  "    \"direction\":   \"<N|NE|E|SE|S|SW|W|NW>\"",
  "  },",
  "  \"fallback_lat\": <decimal degrees or null>,",
  "  \"fallback_lon\": <decimal degrees or null>",
  "}",
  "",
  "Rules:",
  "- Set \"offset\" to null when no directional offset is present.",
  "- Remove elevation values (e.g. \"827m\", \"1800-2000m\").",
  "- Fix clear misspellings (e.g. Mexicó -> Mexico).",
  "- Reformat \"Country : State (detail)\" as \"detail, State, Country\".",
  "- When a directional offset is present (e.g. \"2.5 km NW of Saltillo\"),",
  "  set address = null and populate offset with the base place as geocodeable string.",
  "- If the locality is too vague to geocode, set address = null and offset = null.",
  "- Always populate fallback_lat/fallback_lon with your best coordinate estimate",
  "  (decimal degrees). Set both to null only if you have no reasonable estimate.",
  sep = "\n"
)

# ---- API helpers ----

strip_markdown <- function(x) {
  x <- str_remove(x, "^```(?:json)?\\s*")
  x <- str_remove(x, "\\s*```$")
  trimws(x)
}

# Sends one chunk of locality strings to Gemini.
# Retries indefinitely: MAX_RETRIES inner attempts with exponential backoff,
# then a 60-second pause before the next outer attempt.
call_gemini_batch <- function(localities, label = "") {
  input_json <- toJSON(
    lapply(seq_along(localities), function(i) list(i = i, locality = localities[[i]])),
    auto_unbox = TRUE
  )
  repeat {
    result <- tryCatch({
      resp <- request("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite-preview:generateContent") |>
        req_url_query(key = Sys.getenv("GEMINI_API_KEY")) |>
        req_body_json(list(
          systemInstruction = list(parts = list(list(text = PARSE_PROMPT))),
          contents          = list(list(parts = list(list(text = input_json)))),
          generationConfig  = list(maxOutputTokens = 8192, temperature = 0)
        )) |>
        req_throttle(rate = 15 / 60, realm = "gemini") |>
        req_retry(
          max_tries    = MAX_RETRIES,
          is_transient = \(resp) resp_status(resp) %in% c(429, 500, 502, 503, 504),
          backoff      = \(i) 10 * 2^(i - 1)
        ) |>
        req_perform()
      raw    <- resp_body_json(resp)$candidates[[1]]$content$parts[[1]]$text
      log_gemini(label, input_json, output = raw)
      parsed <- fromJSON(strip_markdown(raw), simplifyVector = FALSE)
      if (!is.list(parsed) || length(parsed) != length(localities)) {
        warning(sprintf(
          "Gemini returned %d result(s) for %d locality/ies in this chunk.",
          length(parsed), length(localities)
        ))
      }
      parsed
    }, error = function(e) {
      msg <- sprintf("Gemini batch failed after %d tries: %s", MAX_RETRIES, conditionMessage(e))
      log_gemini(label, input_json, error = msg)
      warning(msg)
      NULL
    })

    if (!is.null(result)) return(result)
    message("  Service unavailable — retrying batch in 60 seconds...")
    Sys.sleep(60)
  }
}

# Normalize one element from a batch response into list(address, offset, fallback_lat, fallback_lon).
normalize_result <- function(r, fallback_locality) {
  tryCatch({
    list(
      address      = if (is.null(r$address)) NA_character_ else as.character(r$address),
      offset       = if (is.null(r$offset)) NULL else list(
        base        = if (is.null(r$offset$base))      NA_character_ else as.character(r$offset$base),
        distance_km = if (is.null(r$offset$distance_km)) NA_real_    else as.numeric(r$offset$distance_km),
        direction   = if (is.null(r$offset$direction)) NA_character_ else as.character(r$offset$direction)
      ),
      fallback_lat = if (is.null(r$fallback_lat)) NA_real_ else as.numeric(r$fallback_lat),
      fallback_lon = if (is.null(r$fallback_lon)) NA_real_ else as.numeric(r$fallback_lon)
    )
  }, error = function(e) {
    list(address = trimws(fallback_locality), offset = NULL,
         fallback_lat = NA_real_, fallback_lon = NA_real_)
  })
}

default_result <- function(locality) {
  list(address = trimws(locality), offset = NULL,
       fallback_lat = NA_real_, fallback_lon = NA_real_)
}

# ---- Per-species processing ----

for (sp in species) {
  message("Geocoding (LLM): ", sp)
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

  # Step 1: LLM-parse unique non-NA localities in batches
  unique_locs   <- unique(na.omit(combined$locality))
  chunk_indices <- split(seq_along(unique_locs), ceiling(seq_along(unique_locs) / CHUNK_SIZE))
  n_chunks      <- length(chunk_indices)
  message("  Parsing ", length(unique_locs), " unique locality string(s) via LLM (",
          n_chunks, " batch(es) of up to ", CHUNK_SIZE, ")...")

  parse_cache <- set_names(vector("list", length(unique_locs)), unique_locs)

  for (ch in seq_len(n_chunks)) {
    idx   <- chunk_indices[[ch]]
    chunk <- unique_locs[idx]
    message("  Batch ", ch, "/", n_chunks, " (", length(chunk), " localities)...")

    batch_raw <- call_gemini_batch(as.list(chunk),
                                   label = sprintf("%s | Batch %d/%d", sp, ch, n_chunks))

    if (is.null(batch_raw)) {
      for (loc in chunk) parse_cache[[loc]] <- default_result(loc)
    } else {
      result_by_i <- set_names(batch_raw, sapply(batch_raw, function(r) as.character(r$i)))
      for (j in seq_along(chunk)) {
        loc <- chunk[[j]]
        r   <- result_by_i[[as.character(j)]]
        if (is.null(r)) {
          warning("No result returned for locality: ", loc)
          parse_cache[[loc]] <- default_result(loc)
        } else {
          parse_cache[[loc]] <- normalize_result(r, loc)
        }
      }
    }
  }

  # Build geocode_query: use offset$base for offset records, address otherwise
  get_query <- function(loc) {
    if (is.na(loc)) return(NA_character_)
    pr <- parse_cache[[loc]]
    if (!is.null(pr$offset) && !is.na(pr$offset$base)) return(pr$offset$base)
    if (!is.na(pr$address)) return(pr$address)
    NA_character_
  }
  combined <- combined %>%
    mutate(
      geocode_query = map_chr(locality, get_query),
      geocode_type  = "direct"
    )

  # Step 2: Batch geocode unique non-NA queries
  unique_q <- tibble(geocode_query = unique(na.omit(combined$geocode_query)))

  if (nrow(unique_q) > 0) {
    coords <- geocode(unique_q, geocode_query,
                      method = "osm", lat = "lat", long = "lon")

    failed_q <- filter(coords, is.na(lat))
    if (nrow(failed_q) > 0) {
      message("  ", nrow(failed_q), " query/queries failed OSM — trying ArcGIS")
      fb     <- geocode(select(failed_q, geocode_query), geocode_query,
                        method = "arcgis", lat = "lat", long = "lon")
      coords <- bind_rows(filter(coords, !is.na(lat)), fb)
    }

    combined <- left_join(combined, coords, by = "geocode_query")

    # Apply bearing offsets for rows where LLM detected an offset
    for (i in seq_len(nrow(combined))) {
      loc <- combined$locality[i]
      if (is.na(loc)) next
      oi <- parse_cache[[loc]]$offset
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

  # Step 3: LLM coordinate fallback for records still NA (uses parse_cache, no extra API call)
  still_na <- which(is.na(combined$lat) & !is.na(combined$locality))
  if (length(still_na) > 0) {
    message("  ", length(still_na), " record(s) still NA — using cached LLM fallback coordinates")
    for (i in still_na) {
      fc_lat <- parse_cache[[combined$locality[i]]]$fallback_lat
      fc_lon <- parse_cache[[combined$locality[i]]]$fallback_lon
      if (!is.na(fc_lat) && !is.na(fc_lon)) {
        combined$lat[i]          <- fc_lat
        combined$lon[i]          <- fc_lon
        combined$geocode_type[i] <- "llm_approximate"
      } else {
        combined$geocode_type[i] <- "failed"
      }
    }
  }

  # Mark NA-query rows as failed
  combined <- combined %>%
    mutate(
      geocode_type = ifelse(
        is.na(geocode_query) & geocode_type == "direct", "failed", geocode_type
      )
    )

  outpath <- file.path(out_dir, filename)
  write_csv(combined, outpath)
  message("  Written ", nrow(combined), " records to ", outpath)
}

message("Done. CSVs written to ", out_dir, "/")
