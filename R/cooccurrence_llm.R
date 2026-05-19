library(httr2)
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

in_path  <- "data/combined/all_records.csv"
out_dir  <- "data/cooccurrence_llm"
out_path <- file.path(out_dir, "all_records.csv")

if (!file.exists(in_path)) {
  stop("Input not found: ", in_path,
       "\nRun R/combineOccs.R first.")
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

log_dir  <- "Logs"
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
log_path <- file.path(log_dir, paste0("cooccurrence_llm_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))

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

# ---- Prompt ----

EXTRACT_PROMPT <- paste(
  "You are an information-extraction assistant for botanical collection records.",
  "You will receive a JSON array. Each element has an integer 'i', a 'focal_species'",
  "string (the species the record describes), and a 'notes' string (a free-text",
  "field that sometimes mentions co-occurring species).",
  "",
  "Return ONLY a JSON array with exactly one object per input element, preserving 'i'.",
  "No prose, no markdown fences.",
  "",
  "Output schema per element:",
  "{",
  "  \"i\":       <same integer as input>,",
  "  \"species\": [\"Genus epithet ...\", ...]",
  "}",
  "",
  "Task: extract every co-occurring plant species mentioned in 'notes'.",
  "",
  "Co-occurrence MUST be explicitly signaled by a connecting phrase such as:",
  "with, together with, growing with, growing among, in association with,",
  "associated with, amongst, among, accompanied by, alongside, in company with,",
  "sympatric with, syntopic with, near, next to, beside, surrounded by.",
  "",
  "Do NOT extract a species name unless one of these (or a clear paraphrase) appears",
  "in the notes and applies to that name. In particular, DO NOT extract:",
  "- Synonyms or alternative names for the focal species (e.g. '(= Genus species)',",
  "  'aka Genus species', a name in quotes by itself).",
  "- Names introduced by '!', '=', 'syn.', 'cf. only', 'previously known as',",
  "  'identified as', 'sensu', or similar synonym/identification markers.",
  "- Names that are merely listed as taxonomic references, parenthetical authorities,",
  "  or publication citations.",
  "When in doubt, return an empty list rather than a guess.",
  "",
  "PRESERVE TEXT VERBATIM. Do NOT correct spelling. Do NOT drop, rewrite, or",
  "normalize infraspecific ranks ('ssp.', 'subsp.', 'var.', 'v.', 'f.', 'fma.').",
  "Do NOT drop qualifiers like 'cf.' or 'aff.'. Do NOT drop bare 'sp.'. Keep",
  "everything after the genus exactly as written in the source text.",
  "",
  "The ONLY normalization allowed: expand an abbreviated genus (a single capital",
  "letter followed by '.') to its full name, using the epithet and the focal",
  "species' genus as context. Examples:",
  "  'G.spegazzinnii'        -> 'Gymnocalycium spegazzinnii'  (typo preserved)",
  "  'O. cymochila' after 'Opuntia fragilis' -> 'Opuntia cymochila'",
  "  't. duratii'            -> 'Trichocereus duratii'         (expanded genus is Title-cased;",
  "                                                            epithet kept verbatim)",
  "",
  "EXCLUDE the following from the output array:",
  "- Field numbers and collector codes (e.g. 'REP329-331f', '=BLMT63', 'BB1182.01',",
  "  'JO323', 'LH1113'). Anything that is collector initials + digits, or '=' + code,",
  "  is NOT a species.",
  "- Generic plant references with no binomial structure ('grasses', 'bushes',",
  "  'shrubs', 'cacti', 'larrea bushes', 'prosopis bushes').",
  "- The focal species itself if it appears in notes.",
  "",
  "If notes contains no co-occurring species, return \"species\": [].",
  sep = "\n"
)

# ---- API helpers ----

strip_markdown <- function(x) {
  x <- str_remove(x, "^```(?:json)?\\s*")
  x <- str_remove(x, "\\s*```$")
  trimws(x)
}

# Sends one chunk of {focal_species, notes} pairs to Gemini.
# Retries indefinitely: MAX_RETRIES inner attempts with exponential backoff,
# then a 60-second pause before the next outer attempt.
call_gemini_batch <- function(items, label = "") {
  input_json <- toJSON(
    lapply(seq_along(items), function(i) list(
      i             = i,
      focal_species = items[[i]]$focal_species,
      notes         = items[[i]]$notes
    )),
    auto_unbox = TRUE
  )
  repeat {
    result <- tryCatch({
      resp <- request("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite-preview:generateContent") |>
        req_url_query(key = Sys.getenv("GEMINI_API_KEY")) |>
        req_body_json(list(
          systemInstruction = list(parts = list(list(text = EXTRACT_PROMPT))),
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
      if (!is.list(parsed) || length(parsed) != length(items)) {
        warning(sprintf(
          "Gemini returned %d result(s) for %d item(s) in this chunk.",
          length(parsed), length(items)
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

# Normalize one element from a batch response into character vector of species names.
normalize_result <- function(r) {
  tryCatch({
    sp <- r$species
    if (is.null(sp)) return(character(0))
    sp <- vapply(sp, function(x) if (is.null(x)) NA_character_ else as.character(x), character(1))
    sp <- trimws(sp)
    sp <- sp[!is.na(sp) & nzchar(sp)]
    sp
  }, error = function(e) character(0))
}

# ---- Read input ----

message("Reading ", in_path, "...")
df <- read_csv(in_path, col_types = cols(.default = col_character()))
message("  ", nrow(df), " record(s) loaded.")

# Build LLM workload: unique non-empty notes with a representative focal_species each.
notes_jobs <- df |>
  filter(!is.na(notes), nzchar(notes)) |>
  group_by(notes) |>
  summarise(focal_species = first(species), .groups = "drop")

message("Unique non-empty notes: ", nrow(notes_jobs))

# Optional smoke-test cap.
limit_env <- Sys.getenv("COOCCURRENCE_LIMIT")
if (nzchar(limit_env)) {
  n_cap <- suppressWarnings(as.integer(limit_env))
  if (!is.na(n_cap) && n_cap > 0 && n_cap < nrow(notes_jobs)) {
    message("COOCCURRENCE_LIMIT=", n_cap, " — capping unique notes for smoke test.")
    notes_jobs <- notes_jobs[seq_len(n_cap), ]
  }
}

# ---- Batch through Gemini ----

extract_cache <- set_names(vector("list", nrow(notes_jobs)), notes_jobs$notes)

if (nrow(notes_jobs) > 0) {
  chunk_indices <- split(seq_len(nrow(notes_jobs)),
                         ceiling(seq_len(nrow(notes_jobs)) / CHUNK_SIZE))
  n_chunks      <- length(chunk_indices)
  message("Sending ", nrow(notes_jobs), " unique notes to Gemini in ",
          n_chunks, " batch(es) of up to ", CHUNK_SIZE, "...")

  for (ch in seq_len(n_chunks)) {
    idx   <- chunk_indices[[ch]]
    chunk <- notes_jobs[idx, ]
    items <- lapply(seq_len(nrow(chunk)), function(j) list(
      focal_species = chunk$focal_species[[j]],
      notes         = chunk$notes[[j]]
    ))
    message("  Batch ", ch, "/", n_chunks, " (", length(items), " notes)...")

    batch_raw <- call_gemini_batch(items, label = sprintf("Batch %d/%d", ch, n_chunks))

    if (is.null(batch_raw)) {
      for (j in seq_len(nrow(chunk))) extract_cache[[chunk$notes[[j]]]] <- character(0)
    } else {
      result_by_i <- set_names(batch_raw, sapply(batch_raw, function(r) as.character(r$i)))
      for (j in seq_len(nrow(chunk))) {
        r <- result_by_i[[as.character(j)]]
        if (is.null(r)) {
          warning("No result returned for notes: ", chunk$notes[[j]])
          extract_cache[[chunk$notes[[j]]]] <- character(0)
        } else {
          extract_cache[[chunk$notes[[j]]]] <- normalize_result(r)
        }
      }
    }
  }
}

# ---- Attach cooccurring_species column ----

get_cooccur <- function(n) {
  if (is.na(n) || !nzchar(n)) return("")
  hit <- extract_cache[[n]]
  if (is.null(hit) || length(hit) == 0) return("")
  paste(hit, collapse = ";")
}

df <- df |>
  mutate(cooccurring_species = map_chr(notes, get_cooccur))

write_csv(df, out_path)
n_with <- sum(nzchar(df$cooccurring_species))
message("Done. ", n_with, " of ", nrow(df), " record(s) have cooccurring_species; written to ", out_path)
