#!/usr/bin/env Rscript

# Fetch 10-day temperature forecasts for peak day analysis
# Outputs: data/forecast_10day.csv

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(lubridate)
  library(httr)
  library(jsonlite)
})

cat("========================================================================\n", file = stderr())
cat("Fetching 10-Day Temperature Forecast for Peak Day Analysis\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

# Define the 10-day prediction period (FIXED: Nov 20-29, 2025)
prediction_dates <- seq(ymd("2025-11-20"), ymd("2025-11-29"), by = "day")

cat(sprintf("Forecast period: %s to %s\n\n",
            min(prediction_dates), max(prediction_dates)), file = stderr())

# Read weather station mapping
stations <- read_csv("weather_station_mapping_final.csv", show_col_types = FALSE)
cat(sprintf("Loaded %d weather stations\n\n", nrow(stations)), file = stderr())

# Function to get airport coordinates using NWS API
get_airport_coords <- function(icao_code) {
  url <- sprintf("https://api.weather.gov/stations/%s", icao_code)

  tryCatch({
    response <- GET(url, user_agent("PJM Load Forecasting Project"))

    if (status_code(response) == 200) {
      text_content <- content(response, "text", encoding = "UTF-8")
      data <- fromJSON(text_content)
      coords <- data$geometry$coordinates
      return(list(lon = coords[1], lat = coords[2]))
    } else {
      return(NULL)
    }
  }, error = function(e) {
    return(NULL)
  })
}

# Function to get extended forecast from NWS (up to 7 days)
get_nws_extended_forecast <- function(lat, lon, zone_name, target_dates) {
  cat(sprintf("  [%s] ", zone_name), file = stderr())

  # Step 1: Get gridpoint
  points_url <- sprintf("https://api.weather.gov/points/%.4f,%.4f", lat, lon)

  tryCatch({
    points_resp <- GET(points_url, user_agent("PJM Load Forecasting Project"))

    if (status_code(points_resp) != 200) {
      cat("⊙ No gridpoint\n", file = stderr())
      return(NULL)
    }

    points_text <- content(points_resp, "text", encoding = "UTF-8")
    points_data <- fromJSON(points_text)
    forecast_hourly_url <- points_data$properties$forecastHourly

    # Step 2: Get hourly forecast
    Sys.sleep(0.5)  # Rate limiting
    forecast_resp <- GET(forecast_hourly_url, user_agent("PJM Load Forecasting Project"))

    if (status_code(forecast_resp) != 200) {
      cat("⊙ No forecast\n", file = stderr())
      return(NULL)
    }

    forecast_text <- content(forecast_resp, "text", encoding = "UTF-8")
    forecast_data <- fromJSON(forecast_text)
    periods <- forecast_data$properties$periods

    if (length(periods) == 0) {
      cat("⊙ Empty forecast\n", file = stderr())
      return(NULL)
    }

    # Extract temperatures for all target dates
    temps <- data.frame()

    for (i in 1:nrow(periods)) {
      start_time <- ymd_hms(periods$startTime[i])
      temp_f <- periods$temperature[i]

      # Convert to F if needed
      if (periods$temperatureUnit[i] != "F") {
        if (periods$temperatureUnit[i] == "C") {
          temp_f <- temp_f * 9/5 + 32
        }
      }

      # Check if this is for any of our target dates
      if (as.Date(start_time) %in% target_dates) {
        temps <- bind_rows(temps, data.frame(
          load_zone = zone_name,
          datetime = format(start_time, "%Y-%m-%d %H:%M:%S"),
          temp_f = temp_f
        ))
      }
    }

    if (nrow(temps) > 0) {
      unique_days <- n_distinct(as.Date(temps$datetime))
      cat(sprintf("✓ %d days, %d hours\n", unique_days, nrow(temps)), file = stderr())
      return(temps)
    } else {
      cat("⊙ No data for target dates\n", file = stderr())
      return(NULL)
    }

  }, error = function(e) {
    cat(sprintf("✗ Error: %s\n", e$message), file = stderr())
    return(NULL)
  })
}

# Function to duplicate last available day for missing dates
duplicate_last_available_day <- function(zone_name, existing_forecasts, target_dates) {
  # Get the last available date for this zone
  zone_forecasts <- existing_forecasts %>%
    filter(load_zone == zone_name) %>%
    mutate(date = as.Date(datetime))

  if (nrow(zone_forecasts) == 0) {
    return(NULL)
  }

  last_available_date <- max(zone_forecasts$date)

  # Get the 24-hour pattern from the last available day
  last_day_pattern <- zone_forecasts %>%
    filter(date == last_available_date) %>%
    arrange(datetime) %>%
    mutate(hour = hour(ymd_hms(datetime))) %>%
    select(hour, temp_f)

  # Find which dates are missing
  covered_dates <- unique(zone_forecasts$date)
  missing_dates <- target_dates[!target_dates %in% covered_dates]

  if (length(missing_dates) == 0) {
    return(NULL)
  }

  # Create forecast for missing dates by duplicating the last day pattern
  all_forecasts <- data.frame()

  for (missing_date in missing_dates) {
    duplicated_forecast <- last_day_pattern %>%
      mutate(
        load_zone = zone_name,
        datetime = format(force_tz(ymd_hms(paste(missing_date, sprintf("%02d:00:00", hour))),
                                   "America/New_York"),
                         "%Y-%m-%d %H:%M:%S")
      ) %>%
      select(load_zone, datetime, temp_f)

    all_forecasts <- bind_rows(all_forecasts, duplicated_forecast)
  }

  return(all_forecasts)
}

# Collect forecasts for all zones and all 10 days
cat("Fetching extended forecasts from National Weather Service...\n", file = stderr())
all_forecasts <- data.frame()
failed_zones <- c()

for (i in 1:nrow(stations)) {
  zone <- stations$load_area[i]
  icao <- stations$station_icao[i]

  # Get coordinates
  coords <- get_airport_coords(icao)

  if (is.null(coords)) {
    cat(sprintf("  [%s] ⊙ Could not get coordinates\n", zone), file = stderr())
    failed_zones <- c(failed_zones, zone)
    next
  }

  # Get extended forecast
  forecast <- get_nws_extended_forecast(coords$lat, coords$lon, zone, prediction_dates)

  if (!is.null(forecast)) {
    all_forecasts <- bind_rows(all_forecasts, forecast)
  } else {
    failed_zones <- c(failed_zones, zone)
  }

  Sys.sleep(0.5)  # Rate limiting
}

# Duplicate last available day for zones with missing data
cat(sprintf("\nFilling missing days by duplicating last available forecast...\n"), file = stderr())

for (zone in unique(stations$load_area)) {
  zone_forecasts <- all_forecasts %>% filter(load_zone == zone)

  if (nrow(zone_forecasts) == 0) {
    # No data at all for this zone - skip it
    cat(sprintf("  [%s] ✗ No forecast data available\n", zone), file = stderr())
  } else {
    # Check if all 10 days are covered
    covered_days <- n_distinct(as.Date(zone_forecasts$datetime))
    if (covered_days < 10) {
      last_date <- max(as.Date(zone_forecasts$datetime))
      cat(sprintf("  [%s] Only %d/10 days, duplicating from %s\n",
                  zone, covered_days, last_date), file = stderr())
      fallback <- duplicate_last_available_day(zone, all_forecasts, prediction_dates)
      if (!is.null(fallback)) {
        all_forecasts <- bind_rows(all_forecasts, fallback)
      }
    }
  }
}

# Remove duplicates (prefer API data over duplicated days)
all_forecasts <- all_forecasts %>%
  distinct(load_zone, datetime, .keep_all = TRUE)

# Ensure we have complete 24-hour coverage for each zone-day combination
cat("\nEnsuring complete 24-hour coverage...\n", file = stderr())

complete_forecast <- expand.grid(
  load_zone = unique(stations$load_area),
  date = prediction_dates,
  hour = 0:23,
  stringsAsFactors = FALSE
) %>%
  mutate(datetime = format(force_tz(ymd_hms(paste(date, sprintf("%02d:00:00", hour))),
                                    "America/New_York"),
                           "%Y-%m-%d %H:%M:%S")) %>%
  select(-date)

# Join with actual forecasts
complete_forecast <- complete_forecast %>%
  left_join(all_forecasts, by = c("load_zone", "datetime"))

# Fill missing hours using interpolation within each zone-day
complete_forecast <- complete_forecast %>%
  mutate(date = as.Date(datetime)) %>%
  group_by(load_zone, date) %>%
  arrange(hour) %>%
  mutate(
    temp_f = zoo::na.approx(temp_f, na.rm = FALSE)
  ) %>%
  ungroup() %>%
  select(-date)

# For remaining NAs, use zone mean
complete_forecast <- complete_forecast %>%
  group_by(load_zone) %>%
  mutate(temp_f = ifelse(is.na(temp_f), mean(temp_f, na.rm = TRUE), temp_f)) %>%
  ungroup()

# Final fallback: overall mean
overall_mean <- mean(complete_forecast$temp_f, na.rm = TRUE)
complete_forecast <- complete_forecast %>%
  mutate(temp_f = ifelse(is.na(temp_f), overall_mean, temp_f))

# Save 10-day forecast
output_file <- "data/forecast_10day.csv"
write_csv(complete_forecast %>%
            select(load_zone, datetime, temp_f) %>%
            arrange(load_zone, datetime),
          output_file)

cat(sprintf("\n✓ Saved 10-day forecast to: %s\n", output_file), file = stderr())
cat(sprintf("  Total forecasts: %d (expected: %d)\n",
            nrow(complete_forecast), 29 * 10 * 24), file = stderr())

# Summary
cat("\n========================================================================\n", file = stderr())
cat("SUMMARY\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

summary_stats <- complete_forecast %>%
  mutate(date = as.Date(datetime)) %>%
  group_by(load_zone) %>%
  summarise(
    n_days = n_distinct(date),
    n_hours = n(),
    mean_temp = mean(temp_f, na.rm = TRUE),
    min_temp = min(temp_f, na.rm = TRUE),
    max_temp = max(temp_f, na.rm = TRUE),
    .groups = "drop"
  )

cat(sprintf("Forecast period: %s to %s\n", min(prediction_dates), max(prediction_dates)),
    file = stderr())
cat(sprintf("Zones: %d\n", n_distinct(complete_forecast$load_zone)), file = stderr())
cat(sprintf("Days per zone: %d\n", n_distinct(as.Date(complete_forecast$datetime))),
    file = stderr())

incomplete_zones <- summary_stats %>% filter(n_days < 10 | n_hours < 240)
if (nrow(incomplete_zones) > 0) {
  cat("\nWARNING: Incomplete zones:\n", file = stderr())
  print(incomplete_zones)
}

cat("\n========================================================================\n", file = stderr())
cat("Complete!\n", file = stderr())
cat("========================================================================\n", file = stderr())
