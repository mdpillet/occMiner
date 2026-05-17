library(httr)
library(rvest)
library(dplyr)
library(readr)
library(stringr)

BASE_URL          <- "https://fieldnos.bcss.org.uk"
OUT_DIR           <- file.path("data", "bcss")
OUT_CSV           <- file.path(OUT_DIR, "all_records.csv")
STATE_FILE        <- file.path(OUT_DIR, ".scrape_state.csv")
CLCACTUS_BINOMIALS <- file.path("data", "clcactus", ".binomials.csv")
LOG_DIR           <- "Logs"
SLEEP_OK          <- 1
SLEEP_ERR_BASE    <- 5
MAX_RETRIES       <- 3

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(LOG_DIR, recursive = TRUE, showWarnings = FALSE)

LOG_FILE <- file.path(
  LOG_DIR,
  paste0("bcss_miner_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log")
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

# All UN member/observer states + dependent territories + common aliases.
# Aliases double-fetch; the final dedupe collapses duplicate rows.
COUNTRY_QUERIES <- c(
  "Afghanistan", "Albania", "Algeria", "Andorra", "Angola", "Antigua and Barbuda",
  "Argentina", "Armenia", "Australia", "Austria", "Azerbaijan", "Bahamas",
  "Bahrain", "Bangladesh", "Barbados", "Belarus", "Belgium", "Belize", "Benin",
  "Bhutan", "Bolivia", "Bosnia and Herzegovina", "Botswana", "Brazil", "Brunei",
  "Bulgaria", "Burkina Faso", "Burundi", "Cabo Verde", "Cape Verde", "Cambodia",
  "Cameroon", "Canada", "Central African Republic", "Chad", "Chile", "China",
  "Colombia", "Comoros", "Congo", "Democratic Republic of the Congo", "DRC",
  "Costa Rica", "Côte d'Ivoire", "Cote d'Ivoire", "Ivory Coast", "Croatia",
  "Cuba", "Cyprus", "Czechia", "Czech Republic", "Denmark", "Djibouti",
  "Dominica", "Dominican Republic", "Ecuador", "Egypt", "El Salvador",
  "Equatorial Guinea", "Eritrea", "Estonia", "Eswatini", "Swaziland", "Ethiopia",
  "Fiji", "Finland", "France", "Gabon", "Gambia", "Georgia", "Germany", "Ghana",
  "Greece", "Grenada", "Guatemala", "Guinea", "Guinea-Bissau", "Guyana", "Haiti",
  "Honduras", "Hungary", "Iceland", "India", "Indonesia", "Iran", "Iraq",
  "Ireland", "Israel", "Italy", "Jamaica", "Japan", "Jordan", "Kazakhstan",
  "Kenya", "Kiribati", "North Korea", "South Korea", "Korea", "Kosovo",
  "Kuwait", "Kyrgyzstan", "Laos", "Latvia", "Lebanon", "Lesotho", "Liberia",
  "Libya", "Liechtenstein", "Lithuania", "Luxembourg", "Madagascar", "Malawi",
  "Malaysia", "Maldives", "Mali", "Malta", "Marshall Islands", "Mauritania",
  "Mauritius", "Mexico", "Micronesia", "Moldova", "Monaco", "Mongolia",
  "Montenegro", "Morocco", "Mozambique", "Myanmar", "Burma", "Namibia", "Nauru",
  "Nepal", "Netherlands", "Holland", "New Zealand", "Nicaragua", "Niger",
  "Nigeria", "North Macedonia", "Macedonia", "Norway", "Oman", "Pakistan",
  "Palau", "Palestine", "Panama", "Papua New Guinea", "Paraguay", "Peru",
  "Philippines", "Poland", "Portugal", "Qatar", "Romania", "Russia",
  "Russian Federation", "Rwanda", "Saint Kitts and Nevis", "Saint Lucia",
  "Saint Vincent", "Samoa", "San Marino", "Sao Tome and Principe", "Saudi Arabia",
  "Senegal", "Serbia", "Seychelles", "Sierra Leone", "Singapore", "Slovakia",
  "Slovenia", "Solomon Islands", "Somalia", "South Africa", "South Sudan",
  "Spain", "Sri Lanka", "Sudan", "Suriname", "Sweden", "Switzerland", "Syria",
  "Taiwan", "Tajikistan", "Tanzania", "Thailand", "Timor-Leste", "East Timor",
  "Togo", "Tonga", "Trinidad and Tobago", "Tunisia", "Turkey", "Türkiye",
  "Turkmenistan", "Tuvalu", "Uganda", "Ukraine", "United Arab Emirates", "UAE",
  "United Kingdom", "UK", "Britain", "England", "Scotland", "Wales",
  "United States", "USA", "America", "Uruguay", "Uzbekistan", "Vanuatu",
  "Vatican", "Holy See", "Venezuela", "Vietnam", "Yemen", "Zambia", "Zimbabwe",
  # Major dependent / autonomous territories
  "Puerto Rico", "Virgin Islands", "Cayman Islands", "Bermuda", "Aruba",
  "Curacao", "Curaçao", "Bonaire", "Sint Maarten", "Saint Martin", "Anguilla",
  "Montserrat", "Turks and Caicos", "Greenland", "Faroe Islands",
  "French Guiana", "Guadeloupe", "Martinique", "French Polynesia",
  "New Caledonia", "Réunion", "Reunion", "Mayotte", "Falkland Islands",
  "Gibraltar", "Isle of Man", "Jersey", "Guernsey", "Canary Islands",
  "Balearic Islands", "Azores", "Madeira", "Hawaii", "Galapagos",
  "Western Sahara", "Hong Kong", "Macau", "Cook Islands", "Niue",
  "American Samoa", "Guam", "Northern Mariana", "Saba", "Saint Helena",
  # Historical names that may appear in older records
  "USSR", "Soviet", "Yugoslavia", "Czechoslovakia", "Zaire"
)

fetch_html <- function(url) {
  for (attempt in seq_len(MAX_RETRIES)) {
    resp <- tryCatch(GET(url, browser_headers, timeout(60)),
                     error = function(e) e)
    if (inherits(resp, "response") && status_code(resp) == 200) {
      text  <- content(resp, "text", encoding = "UTF-8")
      bytes <- nchar(text, type = "bytes")
      Sys.sleep(SLEEP_OK)
      return(list(page = read_html(text), bytes = bytes))
    }
    status <- if (inherits(resp, "response")) status_code(resp) else NA_integer_
    err    <- if (inherits(resp, "response")) "" else conditionMessage(resp)
    backoff <- SLEEP_ERR_BASE * (2 ^ (attempt - 1))
    log_msg("  HTTP error (status=", status, " ", err, ") on ", url,
            " — retry ", attempt, "/", MAX_RETRIES, " in ", backoff, "s")
    Sys.sleep(backoff)
  }
  log_msg("  Falling back to RSelenium for ", url)
  page <- selenium_fetch(url)
  if (is.null(page)) return(NULL)
  list(page = page, bytes = NA_integer_)
}

format_bytes <- function(n) {
  if (is.na(n)) return("?")
  if (n >= 1e6) sprintf("%.1f MB", n / 1e6)
  else if (n >= 1e3) sprintf("%.1f KB", n / 1e3)
  else sprintf("%d B", n)
}

selenium_fetch <- function(url) {
  ok <- requireNamespace("RSelenium", quietly = TRUE)
  if (!ok) {
    log_msg("  RSelenium not installed — giving up on ", url)
    return(NULL)
  }
  res <- tryCatch({
    rD    <- RSelenium::rsDriver(browser = "chrome", chromever = "latest", verbose = FALSE)
    remDr <- rD$client
    on.exit({
      try(remDr$close(), silent = TRUE)
      try(rD$server$stop(), silent = TRUE)
    }, add = TRUE)
    remDr$navigate(url)
    Sys.sleep(5)
    html <- remDr$getPageSource()[[1]]
    read_html(html)
  }, error = function(e) {
    log_msg("  RSelenium error: ", conditionMessage(e))
    NULL
  })
  if (!is.null(res)) Sys.sleep(SLEEP_OK)
  res
}

clean_text <- function(x) {
  if (is.na(x)) return(NA_character_)
  x <- gsub(" ", " ", x)  # non-breaking spaces
  x <- trimws(x)
  if (nchar(x) == 0) NA_character_ else x
}

extract_sibling_text <- function(node, label) {
  # The value is the text node IMMEDIATELY following <b>Label:</b>. Without the
  # self::text() guard, `following-sibling::text()[1]` skips past an intervening
  # <br> and returns the *next* field's value, e.g. an empty Altitude picks up
  # the Date string.
  result <- node %>%
    html_node(xpath = sprintf('.//b[contains(text(),"%s")]/following-sibling::node()[1][self::text()]', label)) %>%
    html_text()
  clean_text(result)
}

parse_record_node <- function(par) {
  tibble(
    field_number = extract_sibling_text(par, "Field number"),
    collector    = extract_sibling_text(par, "Collector"),
    species      = extract_sibling_text(par, "Species"),
    locality     = extract_sibling_text(par, "Locality"),
    altitude     = extract_sibling_text(par, "Altitude"),
    date         = extract_sibling_text(par, "Date"),
    notes        = extract_sibling_text(par, "Notes")
  )
}

# Regex fallback when the <p>/<b> structure is missing.
parse_page_text <- function(page) {
  lines  <- strsplit(html_text(page), "\n")[[1]]
  lines  <- trimws(lines)
  lines  <- lines[nchar(lines) > 0]
  starts <- grep("^Field number", lines)
  if (length(starts) == 0) return(NULL)
  ends <- c(starts[-1] - 1L, length(lines))
  extract_val <- function(pattern, block) {
    m   <- str_match(block, paste0("^", pattern, "\\s*:?\\s*(.*)$"))
    hit <- m[!is.na(m[, 1]), 2, drop = TRUE]
    if (length(hit) == 0 || nchar(trimws(hit[[1]])) == 0) NA_character_ else trimws(hit[[1]])
  }
  mapply(function(s, e) {
    block <- lines[s:e]
    tibble(
      field_number = extract_val("Field number", block),
      collector    = extract_val("Collector",    block),
      species      = extract_val("Species",      block),
      locality     = extract_val("Locality",     block),
      altitude     = extract_val("Altitude",     block),
      date         = extract_val("Date",         block),
      notes        = extract_val("Notes",        block)
    )
  }, starts, ends, SIMPLIFY = FALSE) %>% bind_rows()
}

find_record_pars <- function(page) {
  pars <- html_elements(page, "p")
  Filter(function(p) grepl("Field number", html_text(p)), pars)
}

parse_record_pars <- function(record_pars) {
  n <- length(record_pars)
  bind_rows(lapply(seq_len(n), function(i) {
    if (i %% 100 == 0) log_msg("    parsed ", i, "/", n, " records")
    parse_record_node(record_pars[[i]])
  }))
}

empty_records <- function() {
  tibble(
    field_number = character(), collector = character(), species  = character(),
    locality     = character(), altitude  = character(), date     = character(),
    notes        = character(), source_url = character()
  )
}

scrape_query <- function(url) {
  fetched <- fetch_html(url)
  if (is.null(fetched)) return(NULL)
  page  <- fetched$page
  bytes <- fetched$bytes

  record_pars <- find_record_pars(page)
  n_pars      <- length(record_pars)
  log_msg("    Fetched (", format_bytes(bytes), ", ~", n_pars,
          " record blocks) — parsing…")

  recs <- if (n_pars > 0) parse_record_pars(record_pars) else parse_page_text(page)
  if (is.null(recs) || nrow(recs) == 0) return(empty_records())
  recs$source_url <- url
  recs[, c("field_number", "collector", "species", "locality",
           "altitude", "date", "notes", "source_url")]
}

load_state <- function() {
  if (file.exists(STATE_FILE)) {
    read_csv(STATE_FILE, show_col_types = FALSE)
  } else {
    tibble(kind = character(), query = character(), status = character(),
           n_records = integer(), fetched_at = character())
  }
}

append_state <- function(kind, query, status, n) {
  row <- tibble(kind = kind, query = query, status = status,
                n_records = as.integer(n),
                fetched_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  write_csv(row, STATE_FILE, append = file.exists(STATE_FILE))
}

append_records <- function(recs) {
  if (nrow(recs) == 0) return(invisible())
  write_csv(recs, OUT_CSV, append = file.exists(OUT_CSV))
}

dedupe_output <- function() {
  if (!file.exists(OUT_CSV)) {
    log_msg("Dedupe: no output file to dedupe")
    return(invisible())
  }
  all <- read_csv(OUT_CSV, show_col_types = FALSE)
  n_before <- nrow(all)
  # Species is case-folded in the key because finder.php echoes the lowercased
  # URL query (`stapelia cedrimontana`) while locality.php preserves the
  # original case (`Stapelia cedrimontana`). Country rows are appended first,
  # so .keep_all retains the proper-cased species value.
  deduped  <- all %>%
    mutate(.species_lc = tolower(species)) %>%
    distinct(field_number, collector, .species_lc, locality, altitude, date,
             notes, .keep_all = TRUE) %>%
    select(-.species_lc)
  write_csv(deduped, OUT_CSV)
  log_msg("Dedupe: ", n_before, " → ", nrow(deduped), " rows")
}

log_msg("=== bcss_miner starting ===")
log_msg("Output: ", OUT_CSV)
log_msg("State:  ", STATE_FILE)

state         <- load_state()
done_pairs    <- paste(state$kind, state$query, sep = "::")[state$status == "done"]
limit         <- suppressWarnings(as.integer(Sys.getenv("BCSS_QUERY_LIMIT", "")))
total_done    <- 0L

is_limit_hit <- function() {
  !is.na(limit) && limit > 0 && total_done >= limit
}

if (!is.na(limit) && limit > 0) {
  log_msg("DEBUG: BCSS_QUERY_LIMIT=", limit, " — restricting total queries this run")
}

log_msg("--- Pass 1: country sweep via locality.php (",
        length(COUNTRY_QUERIES), " queries) ---")
for (country in COUNTRY_QUERIES) {
  if (is_limit_hit()) {
    log_msg("Query limit reached — stopping Pass 1 early")
    break
  }
  key <- paste("country", country, sep = "::")
  if (key %in% done_pairs) {
    log_msg("  SKIP (already done): ", country)
    next
  }
  url <- sprintf("%s/locality.php?Locality=%s", BASE_URL, URLencode(country))
  log_msg("  Country: ", country)
  recs <- tryCatch(scrape_query(url),
                   error = function(e) { log_msg("    ERROR: ", conditionMessage(e)); NULL })
  if (is.null(recs)) {
    append_state("country", country, "failed", 0L)
    next
  }
  append_records(recs)
  append_state("country", country, "done", nrow(recs))
  done_pairs <- c(done_pairs, key)
  total_done <- total_done + 1L
  log_msg("    +", nrow(recs), " records")
}

if (!file.exists(CLCACTUS_BINOMIALS)) {
  log_msg("--- Pass 2: SKIPPED — ", CLCACTUS_BINOMIALS, " not found ---")
} else if (is_limit_hit()) {
  log_msg("--- Pass 2: SKIPPED — query limit reached in Pass 1 ---")
} else {
  binomials <- read_csv(CLCACTUS_BINOMIALS, show_col_types = FALSE)$binomial
  log_msg("--- Pass 2: cl-cactus binomial sweep via finder.php (",
          length(binomials), " queries) ---")
  for (bin in binomials) {
    if (is_limit_hit()) {
      log_msg("Query limit reached — stopping Pass 2 early")
      break
    }
    key <- paste("binomial", bin, sep = "::")
    if (key %in% done_pairs) {
      log_msg("  SKIP (already done): ", bin)
      next
    }
    plant_query <- gsub(" ", "+", tolower(bin))
    url <- sprintf("%s/finder.php?Plant=%s", BASE_URL, plant_query)
    log_msg("  Binomial: ", bin)
    recs <- tryCatch(scrape_query(url),
                     error = function(e) { log_msg("    ERROR: ", conditionMessage(e)); NULL })
    if (is.null(recs)) {
      append_state("binomial", bin, "failed", 0L)
      next
    }
    append_records(recs)
    append_state("binomial", bin, "done", nrow(recs))
    done_pairs <- c(done_pairs, key)
    total_done <- total_done + 1L
    log_msg("    +", nrow(recs), " records")
  }
}

log_msg("--- Dedupe pass ---")
dedupe_output()

log_msg("=== bcss_miner complete ===")
