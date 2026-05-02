library(httr)
library(rvest)
library(dplyr)
library(readr)
library(stringr)

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

dir.create(file.path("data", "clcactus"), recursive = TRUE, showWarnings = FALSE)

browser_headers <- add_headers(
  `User-Agent`      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  `Accept`          = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
  `Accept-Language` = "en-US,en;q=0.5"
)

clean_text <- function(x) {
  if (is.na(x)) return(NA_character_)
  x <- gsub(" ", " ", x)  # non-breaking spaces
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
  # Use the first text node inside the <a> to avoid picking up &nbsp; and <img> alt text
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

parse_record <- function(par) {
  tibble(
    field_number = extract_link_text(par, "Field number"),
    collector    = extract_link_text(par, "Collector"),
    species      = extract_species_text(par),
    locality     = extract_sibling_text(par, "Locality"),
    date         = extract_sibling_text(par, "Date"),
    notes        = extract_sibling_text(par, "Notes")
  )
}

empty_result <- function() {
  tibble(
    field_number = character(),
    collector    = character(),
    species      = character(),
    locality     = character(),
    date         = character(),
    notes        = character()
  )
}

for (sp in species) {
  message("Fetching cl-cactus.com: ", sp)
  plant_query <- gsub(" ", "+", sp)
  url         <- paste0("https://www.cl-cactus.com/fnfinder.asp?Lang=en&Plant=", plant_query)
  filename    <- paste0(gsub(" ", "_", tolower(sp)), ".csv")
  outpath     <- file.path("data", "clcactus", filename)

  tryCatch({
    resp <- GET(url, browser_headers)

    if (status_code(resp) != 200) {
      warning(sprintf("HTTP %d for '%s' — skipping", status_code(resp), sp))
      write_csv(empty_result(), outpath)
      Sys.sleep(5)
      next
    }

    page        <- read_html(content(resp, "text", encoding = "UTF-8"))
    pars        <- html_elements(page, "p")
    record_pars <- Filter(function(p) grepl("Field number", html_text(p)), pars)

    if (length(record_pars) == 0) {
      message("  No records found")
      records <- empty_result()
    } else {
      records <- bind_rows(lapply(record_pars, parse_record))
      message("  Found ", nrow(records), " record(s)")
    }

    write_csv(records, outpath)
    Sys.sleep(2)

  }, error = function(e) {
    warning(sprintf("Error for '%s': %s", sp, conditionMessage(e)))
    write_csv(empty_result(), outpath)
    Sys.sleep(5)
  })
}

message("Done. CSVs written to data/clcactus/")
