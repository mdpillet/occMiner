library(httr)
library(rvest)
library(dplyr)
library(readr)
library(stringr)

species <- c(
  "Ariocarpus fissuratus",
  "Pilosocereus chrysostele",
  "Pilosocereus pachycladus",
  "Thelocactus conothelos"
)

dir.create(file.path("data", "bcss"), recursive = TRUE, showWarnings = FALSE)

browser_headers <- add_headers(
  `User-Agent`      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  `Accept`          = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
  `Accept-Language` = "en-US,en;q=0.5"
)

clean_text <- function(x) {
  if (is.na(x)) return(NA_character_)
  x <- gsub(" ", " ", x)
  x <- trimws(x)
  if (nchar(x) == 0) NA_character_ else x
}

# Fetch URL via httr; fall back to RSelenium if response is not 200.
fetch_page <- function(url) {
  resp <- GET(url, browser_headers)
  if (status_code(resp) == 200) {
    return(read_html(content(resp, "text", encoding = "UTF-8")))
  }

  warning(sprintf("httr returned %d — falling back to RSelenium", status_code(resp)))

  library(RSelenium)
  rD    <- rsDriver(browser = "chrome", chromever = "latest", verbose = FALSE)
  remDr <- rD$client
  on.exit({
    try(remDr$close(), silent = TRUE)
    try(rD$server$stop(), silent = TRUE)
  }, add = TRUE)

  remDr$navigate(url)
  Sys.sleep(5)  # allow Cloudflare / JS to resolve
  html <- remDr$getPageSource()[[1]]
  read_html(html)
}

extract_link_text <- function(node, label) {
  result <- node %>%
    html_node(xpath = sprintf('.//b[contains(text(),"%s")]/following-sibling::a[1]', label)) %>%
    html_text()
  clean_text(result)
}

extract_sibling_text <- function(node, label) {
  result <- node %>%
    html_node(xpath = sprintf('.//b[contains(text(),"%s")]/following-sibling::text()[1]', label)) %>%
    html_text()
  clean_text(result)
}

parse_record_node <- function(par) {
  tibble(
    field_number = extract_link_text(par, "Field number"),
    collector    = extract_link_text(par, "Collector"),
    species      = extract_link_text(par, "Species"),
    locality     = extract_sibling_text(par, "Locality"),
    altitude     = extract_sibling_text(par, "Altitude"),
    date         = extract_sibling_text(par, "Date"),
    notes        = extract_sibling_text(par, "Notes")
  )
}

# Regex fallback when HTML structure is unexpected.
parse_page_text <- function(page, sp) {
  lines  <- strsplit(html_text(page), "\n")[[1]]
  lines  <- trimws(lines)
  lines  <- lines[nchar(lines) > 0]
  starts <- grep("^Field number", lines)

  if (length(starts) == 0) {
    message("  No records found for: ", sp)
    return(NULL)
  }

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

parse_bcss_page <- function(page, sp) {
  # Strategy 1: <p> blocks with <b> label anchors (assumed structure)
  pars        <- html_elements(page, "p")
  record_pars <- Filter(function(p) grepl("Field number", html_text(p)), pars)

  if (length(record_pars) > 0) {
    return(bind_rows(lapply(record_pars, parse_record_node)))
  }

  # Strategy 2: plain-text line regex (handles table / div / unknown layouts)
  message("  <p> strategy found nothing — trying text regex for: ", sp)
  parse_page_text(page, sp)
}

empty_result <- function() {
  tibble(
    field_number = character(),
    collector    = character(),
    species      = character(),
    locality     = character(),
    altitude     = character(),
    date         = character(),
    notes        = character()
  )
}

for (sp in species) {
  message("Fetching BCSS: ", sp)
  plant_query <- gsub(" ", "+", tolower(sp))
  url         <- paste0("https://fieldnos.bcss.org.uk/finder.php?Plant=", plant_query)
  filename    <- paste0(gsub(" ", "_", tolower(sp)), ".csv")
  outpath     <- file.path("data", "bcss", filename)

  tryCatch({
    page    <- fetch_page(url)
    records <- parse_bcss_page(page, sp)

    if (is.null(records)) {
      records <- empty_result()
    }

    message("  Found ", nrow(records), " record(s)")
    write_csv(records, outpath)
    Sys.sleep(2)

  }, error = function(e) {
    warning(sprintf("Error for '%s': %s", sp, conditionMessage(e)))
    write_csv(empty_result(), outpath)
    Sys.sleep(5)
  })
}

message("Done. CSVs written to data/bcss/")
