#!/usr/bin/env Rscript

# Fit models with OPTIMIZED SEASONAL WEIGHTS (3-round cross-validation result)
# Formula: mw ~ temp_f + factor(day_of_week) + factor(hour)
# Weighting: Temporal decay × Optimized seasonal weights

library(lubridate)
library(dplyr)
library(readr)

cat("========================================================================\n")
cat("Fitting Models with Optimized Seasonal Weights\n")
cat("Formula: mw ~ temp_f + factor(day_of_week) + factor(hour) +\n")
cat("              thanksgiving_week * factor(day_of_week)\n")
cat("Weighting: Temporal (exp decay) × Seasonal (3-round CV optimized)\n")
cat("========================================================================\n\n")

# ==============================================================================
# OPTIMIZED SEASONAL WEIGHTS (from 3-round cross-validation)
# ==============================================================================

# Final weights from fine-tuning Round 3
SEASONAL_WEIGHTS <- c(
  0.45,  # Jan - Adjacent winter
  0.00,  # Feb - Peak winter (EXCLUDED)
  1.00,  # Mar - Spring shoulder
  1.00,  # Apr - Spring shoulder
  0.00,  # May - Late spring (EXCLUDED)
  0.00,  # Jun - Summer cooling (EXCLUDED)
  0.00,  # Jul - Summer cooling (EXCLUDED)
  0.00,  # Aug - Summer cooling (EXCLUDED)
  0.05,  # Sep - Early fall transition (nearly excluded)
  1.00,  # Oct - Fall shoulder
  1.00,  # Nov - TARGET MONTH
  0.45   # Dec - Early winter
)

cat("Optimized seasonal weights (from 3-round cross-validation):\n")
for (m in 1:12) {
  status <- if (SEASONAL_WEIGHTS[m] == 0) "EXCLUDED" else
            if (SEASONAL_WEIGHTS[m] == 1) "FULL" else
            sprintf("%.2f", SEASONAL_WEIGHTS[m])
  cat(sprintf("  %3s: %.2f  [%s]\n", month.abb[m], SEASONAL_WEIGHTS[m], status))
}
cat("\n")

# ==============================================================================
# LOAD AND PREPARE DATA
# ==============================================================================

cat("Reading merged load and weather data...\n")
data <- read_csv("data/load_with_weather.csv", show_col_types = FALSE)

cat("Preparing data...\n")

# Function to determine if a date is in Thanksgiving week
# Thanksgiving is the 4th Thursday of November
is_thanksgiving_week <- function(date) {
  if (is.na(date)) return(FALSE)

  d <- as.Date(date)
  m <- month(d)
  y <- year(d)

  # Only November dates can be in Thanksgiving week
  if (is.na(m) || m != 11) return(FALSE)

  # Find the 4th Thursday of November
  nov_dates <- seq(ymd(paste(y, "11", "01", sep="-")),
                   ymd(paste(y, "11", "30", sep="-")),
                   by = "day")
  thursdays <- nov_dates[wday(nov_dates) == 5]  # 5 = Thursday

  if (length(thursdays) < 4) return(FALSE)

  thanksgiving <- thursdays[4]

  # Thanksgiving week is the week containing Thanksgiving
  # Define as Sunday before through Saturday after
  week_start <- thanksgiving - days(wday(thanksgiving) - 1)  # Previous Sunday
  week_end <- week_start + days(6)  # Following Saturday

  return(d >= week_start & d <= week_end)
}

data <- data %>%
  mutate(
    datetime = ymd_hms(datetime, quiet = TRUE),
    day_of_week = wday(datetime, label = FALSE),
    hour = hour(datetime),
    month = month(datetime),
    year = year(datetime),
    thanksgiving_week = sapply(datetime, is_thanksgiving_week)
  ) %>%
  filter(!is.na(temp_f))

cat(sprintf("  Total observations: %d\n", nrow(data)))
cat(sprintf("  Load zones: %d\n", n_distinct(data$load_area)))
cat(sprintf("  Years covered: %s\n",
            paste(sort(unique(year(data$datetime))), collapse=", ")))

# ==============================================================================
# CALCULATE WEIGHTS
# ==============================================================================

cat("\nCalculating weights...\n")

# Temporal weights (exponential decay)
reference_date <- max(data$datetime, na.rm = TRUE)
temporal_half_life <- 0.45  # Optimized via separate cross-validation
lambda <- log(2) / temporal_half_life

cat(sprintf("  Reference date: %s\n", as.Date(reference_date)))
cat(sprintf("  Temporal half-life: %.2f years\n", temporal_half_life))

data <- data %>%
  mutate(
    years_ago = as.numeric(difftime(reference_date, datetime, units = "days")) / 365.25,
    temporal_weight = exp(-lambda * years_ago),
    seasonal_weight = SEASONAL_WEIGHTS[month],
    combined_weight = temporal_weight * seasonal_weight
  )

# Show weight distribution
cat("\nWeight distribution by year and month:\n")
weight_summary <- data %>%
  filter(combined_weight > 0) %>%  # Only non-excluded months
  group_by(year) %>%
  summarise(
    n_obs = n(),
    mean_temporal = mean(temporal_weight),
    mean_seasonal = mean(seasonal_weight),
    mean_combined = mean(combined_weight),
    .groups = "drop"
  ) %>%
  arrange(desc(year))

print(weight_summary)

# Count observations by seasonal weight
cat("\nObservations by seasonal weight category:\n")
seasonal_summary <- data %>%
  mutate(
    category = case_when(
      seasonal_weight == 0 ~ "Excluded (0.0)",
      seasonal_weight < 0.1 ~ "Minimal (0.05)",
      seasonal_weight < 0.5 ~ "Reduced (0.45)",
      seasonal_weight < 1.0 ~ "Partial",
      TRUE ~ "Full (1.0)"
    )
  ) %>%
  group_by(category) %>%
  summarise(n_obs = n(), .groups = "drop") %>%
  arrange(desc(n_obs))

print(seasonal_summary)

effective_sample_size <- sum(data$combined_weight)
cat(sprintf("\nEffective sample size: %.0f (vs %d total observations)\n",
            effective_sample_size, nrow(data)))

# ==============================================================================
# FIT MODELS
# ==============================================================================

cat("\n========================================================================\n")
cat("Fitting Optimized Models\n")
cat("========================================================================\n\n")

models <- list()
performance <- list()

zones <- sort(unique(data$load_area))

for (zone in zones) {
  cat(sprintf("[%s] ", zone))

  zone_data <- data %>% filter(load_area == zone)
  n_obs <- nrow(zone_data)

  if (n_obs < 100) {
    cat(sprintf("⊙ Skipped (only %d observations)\n", n_obs))
    next
  }

  tryCatch({
    # Fit weighted model with Thanksgiving week interaction
    model <- lm(mw ~ temp_f + factor(day_of_week) + factor(hour) +
                     thanksgiving_week * factor(day_of_week),
                data = zone_data,
                weights = combined_weight)

    # Calculate predictions and metrics (weighted)
    predictions <- predict(model, zone_data)
    residuals <- zone_data$mw - predictions

    # Weighted RMSE
    rmse <- sqrt(sum(zone_data$combined_weight * residuals^2) /
                 sum(zone_data$combined_weight))
    mae <- sum(zone_data$combined_weight * abs(residuals)) /
           sum(zone_data$combined_weight)
    r_squared <- summary(model)$r.squared
    adj_r_squared <- summary(model)$adj.r.squared
    mean_load <- sum(zone_data$combined_weight * zone_data$mw) /
                 sum(zone_data$combined_weight)
    pct_error <- 100 * rmse / mean_load

    # Store model
    models[[zone]] <- model

    # Store performance
    performance[[zone]] <- data.frame(
      load_zone = zone,
      n_obs = n_obs,
      mean_load = mean_load,
      rmse = rmse,
      mae = mae,
      pct_error = pct_error,
      r_squared = r_squared,
      adj_r_squared = adj_r_squared,
      temp_coef = coef(model)["temp_f"],
      intercept = coef(model)["(Intercept)"]
    )

    cat(sprintf("✓ N=%d, R²=%.4f, RMSE=%.1f MW (%.1f%% error)\n",
                n_obs, r_squared, rmse, pct_error))

  }, error = function(e) {
    cat(sprintf("✗ Error: %s\n", e$message))
  })
}

# ==============================================================================
# SAVE RESULTS
# ==============================================================================

# Combine performance metrics
perf_df <- bind_rows(performance) %>%
  arrange(desc(r_squared))

cat("\n========================================================================\n")
cat("Model Performance Summary\n")
cat("========================================================================\n\n")

print(as.data.frame(perf_df), row.names = FALSE)

# Save models
models_file <- "data/optimized_models.rds"
saveRDS(models, models_file)
cat(sprintf("\n✓ Saved %d models to: %s\n", length(models), models_file))

# Save performance metrics
perf_file <- "data/optimized_models_performance.csv"
write_csv(perf_df, perf_file)
cat(sprintf("✓ Performance metrics saved to: %s\n", perf_file))

# Summary statistics
cat("\n========================================================================\n")
cat("Overall Performance Statistics\n")
cat("========================================================================\n\n")

cat(sprintf("Number of models fitted: %d\n", length(models)))
cat(sprintf("Seasonal weighting: Optimized (3-round CV)\n"))
cat(sprintf("Temporal half-life: %.2f years\n\n", temporal_half_life))

cat(sprintf("R-squared:\n"))
cat(sprintf("  Mean: %.4f\n", mean(perf_df$r_squared)))
cat(sprintf("  Median: %.4f\n", median(perf_df$r_squared)))

cat(sprintf("\nRMSE (MW):\n"))
cat(sprintf("  Mean: %.1f\n", mean(perf_df$rmse)))
cat(sprintf("  Median: %.1f\n", median(perf_df$rmse)))

cat(sprintf("\nPercent Error:\n"))
cat(sprintf("  Mean: %.1f%%\n", mean(perf_df$pct_error)))
cat(sprintf("  Median: %.1f%%\n", median(perf_df$pct_error)))

cat("\n========================================================================\n")
cat("Complete!\n")
cat("========================================================================\n")
cat("\nModels ready for predictions.\n")
cat("Optimized for November predictions using 3-round CV weights.\n")
cat("\nTo make predictions:\n")
cat("  Rscript make_predictions_optimized.R\n")
cat("\n")
