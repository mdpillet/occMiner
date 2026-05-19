library(httr)
library(rvest)
library(dplyr)
library(readr)
library(stringr)

BASE_URL       <- "https://www.cl-cactus.com"
OUT_DIR        <- file.path("data", "clcactus")
OUT_CSV        <- file.path(OUT_DIR, "all_records.csv")
STATE_FILE     <- file.path(OUT_DIR, ".scrape_state.csv")
BINOMIAL_CACHE <- file.path(OUT_DIR, ".binomials.csv")
LOG_DIR        <- "Logs"
SLEEP_OK       <- 1
SLEEP_ERR_BASE <- 5
MAX_RETRIES    <- 3
NBR_LIST       <- 80

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(LOG_DIR, recursive = TRUE, showWarnings = FALSE)

LOG_FILE <- file.path(
  LOG_DIR,
  paste0("clcactus_miner_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log")
)
log_msg <- function(...) {
  msg <- paste0(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), ..., "\n")
  cat(msg)
  cat(msg, file = LOG_FILE, append = TRUE)
}

browser_headers <- add_headers(
  `User-Agent`      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  `Accept`          = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
  `Accept-Language` = "en-US,en;q=0.5"
)

fetch_html <- function(url) {
  for (attempt in seq_len(MAX_RETRIES)) {
    resp <- tryCatch(GET(url, browser_headers, timeout(30)),
                     error = function(e) e)
    if (inherits(resp, "response") && status_code(resp) == 200) {
      Sys.sleep(SLEEP_OK)
      return(read_html(content(resp, "text", encoding = "UTF-8")))
    }
    status <- if (inherits(resp, "response")) status_code(resp) else NA_integer_
    err    <- if (inherits(resp, "response")) "" else conditionMessage(resp)
    backoff <- SLEEP_ERR_BASE * (2 ^ (attempt - 1))
    log_msg("  HTTP error (status=", status, " ", err, ") on ", url,
            " — retry ", attempt, "/", MAX_RETRIES, " in ", backoff, "s")
    Sys.sleep(backoff)
  }
  log_msg("  GIVING UP on ", url)
  NULL
}

clean_text <- function(x) {
  if (is.na(x)) return(NA_character_)
  x <- gsub(intToUtf8(160L), " ", x, fixed = TRUE)  # non-breaking spaces (U+00A0)
  x <- gsub("[[:space:]]+", " ", x)       # collapse runs of whitespace
  x <- trimws(x)
  if (nchar(x) == 0) NA_character_ else x
}

extract_link_text <- function(node, label) {
  result <- node %>%
    html_node(xpath = sprintf('.//b[contains(text(),"%s")]/following-sibling::a[@class="z1"][1]', label)) %>%
    html_text()
  clean_text(result)
}

extract_species_text <- function(node) {
  result <- node %>%
    html_node(xpath = './/b[contains(text(),"Species")]/following-sibling::a[@class="z1"][1]/text()[1]') %>%
    html_text()
  clean_text(result)
}

extract_sibling_text <- function(node, label) {
  result <- node %>%
    html_node(xpath = sprintf('.//b[contains(text(),"%s")]/following-sibling::text()[1]', label)) %>%
    html_text()
  clean_text(result)
}

extract_fn_id <- function(node) {
  href <- node %>%
    html_node(xpath = './/b[contains(text(),"Field number")]/following-sibling::a[@class="z1"][1]') %>%
    html_attr("href")
  if (is.na(href)) return(NA_character_)
  m <- str_match(href, "FnID=([0-9]+)")
  if (is.na(m[1, 1])) NA_character_ else m[1, 2]
}

parse_record <- function(par) {
  tibble(
    fn_id        = extract_fn_id(par),
    field_number = extract_link_text(par, "Field number"),
    collector    = extract_link_text(par, "Collector"),
    species      = extract_species_text(par),
    locality     = extract_sibling_text(par, "Locality"),
    date         = extract_sibling_text(par, "Date"),
    notes        = extract_sibling_text(par, "Notes")
  )
}

discover_genera <- function() {
  log_msg("Discovering genera from ", BASE_URL, "/")
  page <- fetch_html(paste0(BASE_URL, "/"))
  if (is.null(page)) stop("Could not fetch front page")
  vals <- page %>%
    html_node('select[name="selGenres"]') %>%
    html_nodes("option") %>%
    html_attr("value")
  vals <- vals[!is.na(vals) & nchar(vals) > 0 & vals != "?"]
  log_msg("Found ", length(vals), " genera")
  vals
}

normalize_binomial <- function(species_text) {
  if (is.na(species_text)) return(NA_character_)
  parts <- str_split(trimws(species_text), "\\s+")[[1]]
  if (length(parts) < 2) return(NA_character_)
  epithet <- parts[2]
  # Skip qualifier-like second words (e.g., "aff.", "sp.", "v.")
  if (!str_detect(epithet, "^[a-z][a-z\\-]+$")) return(NA_character_)
  paste(parts[1], epithet)
}

fetch_genus_page <- function(genus, page_offset) {
  url <- sprintf(
    "%s/genres.asp?Lang=en&genres=%s&NbrList=%d&page=%d&OrderBy=Species",
    BASE_URL, URLencode(genus), NBR_LIST, page_offset
  )
  fetch_html(url)
}

discover_binomials <- function(genus) {
  binomials <- character()
  offset <- 0
  repeat {
    page <- fetch_genus_page(genus, offset)
    if (is.null(page)) {
      log_msg("  [", genus, "] page offset ", offset, " unreadable — stopping pagination")
      break
    }
    rows <- html_nodes(page, "tr.body")
    if (length(rows) == 0) break
    species_cells <- rows %>%
      html_node("td:nth-child(1) a") %>%
      html_text()
    bins <- unique(na.omit(vapply(species_cells, normalize_binomial, character(1),
                                  USE.NAMES = FALSE)))
    binomials <- unique(c(binomials, bins))
    if (length(rows) < NBR_LIST) break
    offset <- offset + NBR_LIST
  }
  binomials
}

scrape_binomial <- function(genus, binomial) {
  parts   <- str_split(binomial, "\\s+", n = 2)[[1]]
  epithet <- if (length(parts) >= 2) parts[2] else ""
  query   <- paste(genus, epithet, sep = "+")
  url     <- sprintf("%s/fnfinder.asp?Lang=en&Plant=%s", BASE_URL, query)
  page    <- fetch_html(url)
  if (is.null(page)) return(NULL)
  pars        <- html_elements(page, "p")
  record_pars <- Filter(function(p) grepl("Field number", html_text(p)), pars)
  if (length(record_pars) == 0) {
    return(tibble(
      fn_id = character(), field_number = character(), collector = character(),
      species = character(), genus = character(), locality = character(),
      date = character(), notes = character(), source_url = character()
    ))
  }
  recs <- bind_rows(lapply(record_pars, parse_record))
  recs$genus      <- genus
  recs$source_url <- url
  recs[, c("fn_id", "field_number", "collector", "species", "genus",
           "locality", "date", "notes", "source_url")]
}

load_state <- function() {
  if (file.exists(STATE_FILE)) {
    read_csv(STATE_FILE, show_col_types = FALSE)
  } else {
    tibble(genus = character(), binomial = character(),
           status = character(), n_records = integer(),
           fetched_at = character())
  }
}

append_state <- function(genus, binomial, status, n) {
  row <- tibble(genus = genus, binomial = binomial,
                status = status, n_records = as.integer(n),
                fetched_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  write_csv(row, STATE_FILE, append = file.exists(STATE_FILE))
}

append_records <- function(recs) {
  if (nrow(recs) == 0) return(invisible())
  write_csv(recs, OUT_CSV, append = file.exists(OUT_CSV))
}

load_binomial_cache <- function() {
  if (file.exists(BINOMIAL_CACHE)) {
    read_csv(BINOMIAL_CACHE, show_col_types = FALSE)
  } else {
    tibble(genus = character(), binomial = character())
  }
}

append_binomial_cache <- function(genus, binomials) {
  if (length(binomials) == 0) return(invisible())
  write_csv(
    tibble(genus = genus, binomial = binomials),
    BINOMIAL_CACHE,
    append = file.exists(BINOMIAL_CACHE)
  )
}

log_msg("=== clcactus_miner starting ===")
log_msg("Output: ", OUT_CSV)
log_msg("State:  ", STATE_FILE)

state          <- load_state()
done_binomials <- state %>% filter(status == "done") %>% pull(binomial)
bin_cache      <- load_binomial_cache()
cached_genera  <- unique(bin_cache$genus)

genera <- discover_genera()

limit <- suppressWarnings(as.integer(Sys.getenv("CLCACTUS_GENUS_LIMIT", "")))
if (!is.na(limit) && limit > 0) {
  log_msg("DEBUG: limiting to first ", limit, " genera (CLCACTUS_GENUS_LIMIT)")
  genera <- head(genera, limit)
}

for (i in seq_along(genera)) {
  g <- genera[i]
  log_msg("[", i, "/", length(genera), "] Genus: ", g)

  if (g %in% cached_genera) {
    binomials <- bin_cache$binomial[bin_cache$genus == g]
    log_msg("  Using cached binomial list (", length(binomials), ")")
  } else {
    binomials <- discover_binomials(g)
    append_binomial_cache(g, binomials)
    log_msg("  Discovered ", length(binomials), " binomial(s)")
  }

  for (bin in binomials) {
    if (bin %in% done_binomials) {
      log_msg("  SKIP (already done): ", bin)
      next
    }
    log_msg("  Scraping: ", bin)
    recs <- tryCatch(
      scrape_binomial(g, bin),
      error = function(e) { log_msg("    ERROR: ", conditionMessage(e)); NULL }
    )
    if (is.null(recs)) {
      append_state(g, bin, "failed", 0L)
      next
    }
    append_records(recs)
    append_state(g, bin, "done", nrow(recs))
    done_binomials <- c(done_binomials, bin)
    log_msg("    +", nrow(recs), " records")
  }
}

log_msg("=== clcactus_miner complete ===")
