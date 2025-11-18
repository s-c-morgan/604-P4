#!/usr/bin/env Rscript

# Fetch tomorrow's temperature forecast
# Uses National Weather Service API and airport METAR data as fallback
# Output: data/forecast_YYYY-MM-DD.csv

library(dplyr)
library(readr)
library(lubridate)
library(httr)
library(jsonlite)

cat("========================================================================\n")
cat("Fetching Temperature Forecast\n")
cat("========================================================================\n\n")

# Determine forecast date (tomorrow)
forecast_date <- Sys.Date() + days(1)
cat(sprintf("Target date: %s\n", forecast_date))

# Read weather station mapping
stations <- read_csv("weather_station_mapping_final.csv", show_col_types = FALSE)
cat(sprintf("Loaded %d weather stations\n\n", nrow(stations)))

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

# Function to get hourly forecast from NWS
get_nws_forecast <- function(lat, lon, zone_name) {
  cat(sprintf("  [%s] ", zone_name))

  # Step 1: Get gridpoint
  points_url <- sprintf("https://api.weather.gov/points/%.4f,%.4f", lat, lon)

  tryCatch({
    points_resp <- GET(points_url, user_agent("PJM Load Forecasting Project"))

    if (status_code(points_resp) != 200) {
      cat("⊙ No gridpoint\n")
      return(NULL)
    }

    points_text <- content(points_resp, "text", encoding = "UTF-8")
    points_data <- fromJSON(points_text)
    forecast_hourly_url <- points_data$properties$forecastHourly

    # Step 2: Get hourly forecast
    Sys.sleep(0.5)  # Rate limiting
    forecast_resp <- GET(forecast_hourly_url, user_agent("PJM Load Forecasting Project"))

    if (status_code(forecast_resp) != 200) {
      cat("⊙ No forecast\n")
      return(NULL)
    }

    forecast_text <- content(forecast_resp, "text", encoding = "UTF-8")
    forecast_data <- fromJSON(forecast_text)
    periods <- forecast_data$properties$periods

    if (length(periods) == 0) {
      cat("⊙ Empty forecast\n")
      return(NULL)
    }

    # Extract temperature for target date
    temps <- data.frame()

    for (i in 1:nrow(periods)) {
      start_time <- ymd_hms(periods$startTime[i])
      temp_f <- periods$temperature[i]

      # NWS API returns temperature in F by default
      if (periods$temperatureUnit[i] != "F") {
        # Convert if not in Fahrenheit
        if (periods$temperatureUnit[i] == "C") {
          temp_f <- temp_f * 9/5 + 32
        }
      }

      # Check if this is for our target date
      if (as.Date(start_time) == forecast_date) {
        temps <- bind_rows(temps, data.frame(
          load_zone = zone_name,
          datetime = format(start_time, "%Y-%m-%d %H:%M:%S"),
          temp_f = temp_f
        ))
      }
    }

    if (nrow(temps) > 0) {
      cat(sprintf("✓ %d hours\n", nrow(temps)))
      return(temps)
    } else {
      cat("⊙ No data for target date\n")
      return(NULL)
    }

  }, error = function(e) {
    cat(sprintf("✗ Error: %s\n", e$message))
    return(NULL)
  })
}

# Function to use historical November average as fallback
get_historical_average <- function(zone_name) {
  if (!file.exists("data/temperature_data.csv")) {
    return(NULL)
  }

  weather <- read_csv("data/temperature_data.csv", show_col_types = FALSE)

  nov_avg <- weather %>%
    filter(load_zone == zone_name) %>%
    mutate(
      datetime = ymd_hms(datetime),
      month = month(datetime),
      hour = hour(datetime)
    ) %>%
    filter(month == 11) %>%
    group_by(hour) %>%
    summarise(temp_f = mean(temp_f, na.rm = TRUE), .groups = "drop")

  if (nrow(nov_avg) == 0) {
    return(NULL)
  }

  # Create 24-hour forecast using historical averages
  forecast_temps <- nov_avg %>%
    mutate(
      load_zone = zone_name,
      datetime = ymd_hms(paste(forecast_date, sprintf("%02d:00:00", hour)))
    ) %>%
    select(load_zone, datetime, temp_f)

  return(forecast_temps)
}

# Collect forecasts for all zones
cat("Fetching forecasts from National Weather Service...\n")
all_forecasts <- data.frame()
failed_zones <- c()

for (i in 1:nrow(stations)) {
  zone <- stations$load_area[i]
  icao <- stations$station_icao[i]

  # Get coordinates
  coords <- get_airport_coords(icao)

  if (is.null(coords)) {
    cat(sprintf("  [%s] ⊙ Could not get coordinates\n", zone))
    failed_zones <- c(failed_zones, zone)
    next
  }

  # Get forecast
  forecast <- get_nws_forecast(coords$lat, coords$lon, zone)

  if (!is.null(forecast)) {
    all_forecasts <- bind_rows(all_forecasts, forecast)
  } else {
    failed_zones <- c(failed_zones, zone)
  }

  Sys.sleep(0.5)  # Rate limiting
}

# Use historical averages as fallback for failed zones
if (length(failed_zones) > 0) {
  cat(sprintf("\n%d zones failed, using historical November averages...\n",
              length(failed_zones)))

  for (zone in failed_zones) {
    cat(sprintf("  [%s] ", zone))
    fallback <- get_historical_average(zone)

    if (!is.null(fallback)) {
      all_forecasts <- bind_rows(all_forecasts, fallback)
      cat("✓ Historical average\n")
    } else {
      cat("✗ No fallback available\n")
    }
  }
}

# Ensure we have 24 hours for each zone
cat("\nFilling gaps with interpolation...\n")

complete_forecast <- expand.grid(
  load_zone = unique(stations$load_area),
  hour = 0:23,
  stringsAsFactors = FALSE
) %>%
  mutate(datetime = ymd_hms(paste(forecast_date, sprintf("%02d:00:00", hour))))

# Join with actual forecasts
if (nrow(all_forecasts) > 0) {
  complete_forecast <- complete_forecast %>%
    left_join(
      all_forecasts %>% mutate(datetime = ymd_hms(datetime)),
      by = c("load_zone" = "load_zone", "datetime" = "datetime")
    )
} else {
  # If no forecasts were fetched, create temp_f column with NAs
  complete_forecast$temp_f <- NA_real_
}

# Fill missing hours using interpolation within each zone
complete_forecast <- complete_forecast %>%
  group_by(load_zone) %>%
  arrange(hour) %>%
  mutate(
    temp_f = zoo::na.approx(temp_f, na.rm = FALSE)
  ) %>%
  ungroup()

# For zones still with NAs, use overall mean
overall_mean <- mean(complete_forecast$temp_f, na.rm = TRUE)
complete_forecast <- complete_forecast %>%
  mutate(temp_f = ifelse(is.na(temp_f), overall_mean, temp_f))

# Format datetime as string
complete_forecast <- complete_forecast %>%
  mutate(datetime = format(datetime, "%Y-%m-%d %H:%M:%S")) %>%
  select(load_zone, datetime, temp_f) %>%
  arrange(load_zone, datetime)

# Save forecast
output_file <- sprintf("data/forecast_%s.csv", forecast_date)
write_csv(complete_forecast, output_file)

cat(sprintf("\n✓ Saved %d forecasts to: %s\n", nrow(complete_forecast), output_file))

# Summary statistics
cat("\n========================================================================\n")
cat("SUMMARY\n")
cat("========================================================================\n\n")

summary_stats <- complete_forecast %>%
  group_by(load_zone) %>%
  summarise(
    n_hours = n(),
    mean_temp = mean(temp_f, na.rm = TRUE),
    min_temp = min(temp_f, na.rm = TRUE),
    max_temp = max(temp_f, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(load_zone)

cat(sprintf("Date: %s\n", forecast_date))
cat(sprintf("Zones: %d\n", n_distinct(complete_forecast$load_zone)))
cat(sprintf("Total forecasts: %d\n", nrow(complete_forecast)))
cat(sprintf("Expected: %d (29 zones × 24 hours)\n\n", 29 * 24))

incomplete_zones <- summary_stats %>% filter(n_hours < 24)
if (nrow(incomplete_zones) > 0) {
  cat("WARNING: Incomplete zones:\n")
  print(incomplete_zones)
}

cat("\nTemperature ranges by zone:\n")
print(summary_stats, n = Inf)

cat("\n========================================================================\n")
cat("Complete!\n")
cat("========================================================================\n")
