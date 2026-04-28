library(readr)
library(dplyr)
library(purrr)
library(stringr)
library(sf)

kml_dir <- "data/kml"
shp_dir <- "data/shp"
dir.create(kml_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(shp_dir, recursive = TRUE, showWarnings = FALSE)

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

# Shapefile field names are capped at 10 chars; rename the three that exceed it.
make_shp <- function(data, shp_path) {
  data <- filter(data, !is.na(lat), !is.na(lon)) %>%
    rename(field_no = field_number, gc_query = geocode_query, gc_type = geocode_type) %>%
    st_as_sf(coords = c("lon", "lat"), crs = 4326)
  st_write(data, shp_path, delete_layer = TRUE, quiet = TRUE)
}

pipelines <- list(
  list(dir = "data/geocoded",     label = "geocoded"),
  list(dir = "data/geocoded_llm", label = "geocoded_llm")
)

for (pl in pipelines) {
  kml_pl <- file.path(kml_dir, pl$label)
  shp_pl <- file.path(shp_dir, pl$label)
  dir.create(kml_pl, recursive = TRUE, showWarnings = FALSE)
  dir.create(shp_pl, recursive = TRUE, showWarnings = FALSE)

  for (csv_path in list.files(pl$dir, pattern = "\\.csv$", full.names = TRUE)) {
    sp_snake  <- tools::file_path_sans_ext(basename(csv_path))
    sp_label  <- str_to_title(str_replace_all(sp_snake, "_", " "))
    kml_path  <- file.path(kml_pl, paste0(sp_snake, ".kml"))
    shp_path  <- file.path(shp_pl, paste0(sp_snake, ".shp"))

    data <- read_csv(csv_path, show_col_types = FALSE)
    n    <- sum(!is.na(data$lat))

    kml  <- make_kml(data, sprintf("%s — %s", sp_label, pl$label))
    writeLines(kml, kml_path)

    make_shp(data, shp_path)

    message("Written ", n, " records to ", kml_path, " and ", shp_path)
  }
}

message("Done. KML files written to ", kml_dir, "/")
message("Done. SHP files written to ", shp_dir, "/")
