# occMiner

Scrapes cactus collection records from two hobbyist databases and geocodes the free-text locality strings to decimal coordinates. Built in R.

## Species covered

- *Ariocarpus fissuratus*
- *Pilosocereus chrysostele*
- *Pilosocereus pachycladus*
- *Thelocactus conothelos*

## Pipeline

```
bcss_miner.R      →  data/bcss/<species>.csv
clcactus_miner.R  →  data/clcactus/<species>.csv
                          ↓
geocoder.R        →  data/geocoded/<species>.csv      (regex pipeline)
geocoder_llm.R    →  data/geocoded_llm/<species>.csv  (LLM pipeline)
                          ↓
mapCreator.R      →  data/kml/geocoded/<species>.kml
                      data/kml/geocoded_llm/<species>.kml
                      data/shp/geocoded/<species>.shp
                      data/shp/geocoded_llm/<species>.shp
```

Run each script from the project root with `Rscript R/<script>.R`.

## Data sources

| Script | Source | URL pattern |
|---|---|---|
| `bcss_miner.R` | British Cactus & Succulent Society field number database | `fieldnos.bcss.org.uk/finder.php?Plant=<species>` |
| `clcactus_miner.R` | CL-Cactus field number finder | `cl-cactus.com/fnfinder.asp?Lang=en&Plant=<species>` |

BCSS scraping uses `httr` with browser headers and falls back to RSelenium if a non-200 response is returned (Cloudflare protection). cl-cactus.com is fetched directly via `httr`.

## Output schema

All geocoded CSVs share the same columns:

| Column | Description |
|---|---|
| `field_number` | Collector field number |
| `collector` | Collector name |
| `species` | Taxon name |
| `locality` | Raw locality string as scraped |
| `altitude` | Altitude string as scraped |
| `date` | Collection date |
| `notes` | Additional notes |
| `source` | Source database (`bcss` or `clcactus`) |
| `geocode_query` | The string actually submitted to the geocoder |
| `geocode_type` | How coordinates were obtained (see below) |
| `lat` | Decimal latitude (WGS 84), or `NA` if geocoding failed |
| `lon` | Decimal longitude (WGS 84), or `NA` if geocoding failed |

## Geocode type workflows

Both pipelines assign each record a `geocode_type` that describes how (or whether) coordinates were obtained. The workflows differ between the two scripts.

### `geocoder.R` (regex pipeline)

Locality strings are cleaned and parsed entirely with regular expressions before being submitted to OSM (Nominatim) and, if that fails, ArcGIS.

#### `direct`
The locality string was geocodable as-is after light cleaning (stripping elevation tokens, fixing common misspellings, reformatting "Country: State (detail)" notation). The cleaned string is submitted directly to OSM → ArcGIS.

> Example locality: `"Cuatro Ciénegas, Coahuila, Mexico"`
> Query submitted: `"Cuatro Ciénegas, Coahuila, Mexico"`

#### `direction_only`
A directional phrase was detected (e.g. "North of X", "W of X") but **no distance** was given, so the offset cannot be computed. The base place name is extracted and geocoded; the returned coordinates are the centroid of that place, not the actual collection site.

> Example locality: `"North of Sierra de la Paila, Coahuila, Mexico"`
> Query submitted: `"Sierra de la Paila, Coahuila, Mexico"` (direction discarded)

#### `offset_adjusted`
A directional phrase **with a distance** was detected (e.g. "5 km NW of Saltillo"). The base place is geocoded first, then the coordinates are displaced along the stated bearing using the spherical haversine formula.

> Example locality: `"5km N of Hot Springs, Texas, USA"`
> Query submitted: `"Hot Springs, Texas, USA"` → result shifted 5 km north

#### `failed`
The locality string was too vague to parse, or both OSM and ArcGIS returned no result. `lat` and `lon` are `NA`.

---

### `geocoder_llm.R` (LLM pipeline)

Locality strings are first interpreted by Gemini 3.1 Flash Lite, which parses each string into a structured JSON object containing a cleaned address, an optional directional offset, and fallback coordinates. Unique locality strings are sent in batches of up to 50 per API request. Parsed results are cached so that no locality incurs more than one API call.

```
locality strings (batched, up to 50 per call)
        ↓
  Gemini 3.1 Flash Lite
        ↓ returns per locality:
          address       – clean geocodeable string (or null)
          offset        – {base, distance_km, direction} (or null)
          fallback_lat  – LLM best-guess coordinate
          fallback_lon
        ↓
  OSM → ArcGIS geocoding (on unique queries)
        ↓
  bearing offset applied where offset present
        ↓
  LLM fallback coordinates used if OSM + ArcGIS both fail
```

The `geocode_type` values are identical to the regex pipeline plus one addition:

#### `direct`
Gemini returned a clean address with no directional offset. Geocoded via OSM → ArcGIS.

#### `direction_only`
Gemini detected a directional phrase but returned no distance. The base place is geocoded and its centroid used.

#### `offset_adjusted`
Gemini detected a directional phrase with a distance. The base place is geocoded and coordinates are displaced by the stated bearing and distance.

#### `llm_approximate`
OSM and ArcGIS both failed to geocode the query, but Gemini's `fallback_lat`/`fallback_lon` (returned in the same API call as the parse result) are available and used instead. Accuracy is lower than geocoder-derived coordinates.

#### `failed`
All methods failed: the query returned no geocoder result and Gemini returned null fallback coordinates. `lat` and `lon` are `NA`.

---

### Choosing between pipelines

| | `geocoder.R` | `geocoder_llm.R` |
|---|---|---|
| External dependencies | None beyond R packages | Gemini API key |
| API calls | 0 (uses free Nominatim/ArcGIS) | 1 per ~50 unique localities |
| Directional parsing | Regex (fast, deterministic) | LLM (flexible, handles unusual phrasing) |
| Fallback for failed geocodes | None — record marked `failed` | LLM approximate coordinates |
| Rate limit | Nominatim: 1 req/s | Gemini free tier: 15 req/min |

## KML output

`mapCreator.R` converts geocoded CSVs to KML and shapefile (SHP) for visualisation in Google Earth, QGIS, or any GIS tool. It produces one file per species per pipeline:

```
data/kml/
  geocoded/
    ariocarpus_fissuratus.kml
    pilosocereus_chrysostele.kml
    pilosocereus_pachycladus.kml
    thelocactus_conothelos.kml
  geocoded_llm/
    (same four files)
data/shp/
  geocoded/
    ariocarpus_fissuratus.shp  (+ .dbf, .prj, .shx)
    pilosocereus_chrysostele.shp
    pilosocereus_pachycladus.shp
    thelocactus_conothelos.shp
  geocoded_llm/
    (same four files)
```

Each placemark is colour-coded by `geocode_type` and includes a metadata table (field number, collector, locality, date, source, geocode query and type) in its description popup.

| `geocode_type` | Colour |
|---|---|
| `direct` | Green |
| `direction_only` | Orange |
| `offset_adjusted` | Blue |
| `llm_approximate` | Purple |
| `failed` | Red |

Records with no coordinates (`lat`/`lon` = `NA`) are excluded.

## Setup

### Dependencies

```r
install.packages(c(
  "httr", "rvest",          # scraping
  "httr2", "jsonlite",      # LLM pipeline
  "tidygeocoder",            # geocoding
  "dplyr", "readr", "stringr", "purrr"
))
```

RSelenium is only needed as a fallback for BCSS if Cloudflare blocks the direct request.

### Gemini API key (LLM pipeline only)

Add to `~/.Renviron`:

```
GEMINI_API_KEY=your_key_here
```

Then restart R or run `readRenviron("~/.Renviron")`.

The script uses the **Gemini 3.1 Flash Lite Preview** model (`gemini-3.1-flash-lite-preview`), which is available on the free tier. Rate limiting is handled automatically via `httr2::req_throttle()` (15 RPM). Failed requests are retried up to 3 times with exponential backoff (10 s, 20 s, 40 s).
