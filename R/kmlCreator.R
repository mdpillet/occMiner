library(readr)
library(dplyr)
library(purrr)
library(stringr)

out_dir <- "data/kml"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# KML icon colors per geocode_type (aabbggrr)
type_styles <- c(
  direct           = "ff4db34d",  # green
  direction_only   = "ff00aaff",  # orange
  offset_adjusted  = "ffff6600",  # blue
  llm_approximate  = "ffff00cc",  # purple
  failed           = "ff0000cc"   # red
)

xml_escape <- function(x) {
  x <- str_replace_all(x, "&",  "&amp;")
  x <- str_replace_all(x, "<",  "&lt;")
  x <- str_replace_all(x, ">",  "&gt;")
  x <- str_replace_all(x, '"', "&quot;")
  x
}

make_style_xml <- function(id, color) {
  sprintf(paste0(
    "  <Style id=\"%s\">\n",
    "    <IconStyle>\n",
    "      <color>%s</color><scale>0.8</scale>\n",
    "      <Icon><href>http://maps.google.com/mapfiles/kml/paddle/wht-circle.png</href></Icon>\n",
    "    </IconStyle>\n",
    "  </Style>"
  ), id, color)
}

# Takes all 12 columns explicitly to avoid ... forwarding issues with pmap.
make_placemark <- function(field_number, collector, species, locality, altitude,
                            date, notes, source, geocode_query, geocode_type,
                            lat, lon, ...) {
  style_id <- if (!is.na(geocode_type) && geocode_type %in% names(type_styles))
    geocode_type else "failed"

  name <- if (!is.na(field_number) && nchar(trimws(field_number)) > 0)
    field_number
  else if (!is.na(locality))
    str_trunc(locality, 50)
  else
    "Unknown"

  fields <- c(
    "Field number"  = field_number,
    "Collector"     = collector,
    "Species"       = species,
    "Locality"      = locality,
    "Altitude"      = altitude,
    "Date"          = date,
    "Notes"         = notes,
    "Source"        = source,
    "Geocode query" = geocode_query,
    "Geocode type"  = geocode_type
  )
  rows <- paste(
    sprintf("<tr><td><b>%s</b></td><td>%s</td></tr>",
            names(fields),
            ifelse(is.na(fields), "", xml_escape(as.character(fields)))),
    collapse = ""
  )
  desc <- sprintf("<![CDATA[<table>%s</table>]]>", rows)

  sprintf(paste0(
    "      <Placemark>\n",
    "        <name>%s</name>\n",
    "        <styleUrl>#%s</styleUrl>\n",
    "        <description>%s</description>\n",
    "        <Point><coordinates>%.6f,%.6f,0</coordinates></Point>\n",
    "      </Placemark>"
  ), xml_escape(name), style_id, desc, lon, lat)
}

make_kml <- function(data, doc_name) {
  data <- filter(data, !is.na(lat), !is.na(lon))

  styles     <- paste(mapply(make_style_xml, names(type_styles), type_styles),
                      collapse = "\n")
  placemarks <- paste(pmap_chr(data, make_placemark), collapse = "\n")

  sprintf(paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n",
    "<Document>\n",
    "  <name>%s</name>\n",
    "%s\n",
    "%s\n",
    "</Document>\n",
    "</kml>"
  ), xml_escape(doc_name), styles, placemarks)
}

pipelines <- list(
  list(dir = "data/geocoded",     label = "geocoded"),
  list(dir = "data/geocoded_llm", label = "geocoded_llm")
)

for (pl in pipelines) {
  kml_dir <- file.path(out_dir, pl$label)
  dir.create(kml_dir, recursive = TRUE, showWarnings = FALSE)

  for (csv_path in list.files(pl$dir, pattern = "\\.csv$", full.names = TRUE)) {
    sp_snake <- tools::file_path_sans_ext(basename(csv_path))
    sp_label <- str_to_title(str_replace_all(sp_snake, "_", " "))
    out_path  <- file.path(kml_dir, paste0(sp_snake, ".kml"))

    data <- read_csv(csv_path, show_col_types = FALSE)
    kml  <- make_kml(data, sprintf("%s — %s", sp_label, pl$label))
    writeLines(kml, out_path)
    message("Written ", sum(!is.na(data$lat)), " placemarks to ", out_path)
  }
}

message("Done. KML files written to ", out_dir, "/")
