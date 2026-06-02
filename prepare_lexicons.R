# prepare_lexicons.R
# Run this once locally BEFORE deploying QualiViz.
# It creates local sentiment lexicon files used by app.R so the app
# does not ask users to download NRC / AFINN / Bing interactively.

# 1. Install required packages if needed
required_packages <- c("tidytext", "textdata", "readr", "dplyr")

missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0) {
  install.packages(missing_packages)
}

invisible(lapply(required_packages, library, character.only = TRUE))

# 2. Create app data folder
dir.create("data", showWarnings = FALSE)

# 3. Download/cache lexicons if needed
# NRC may ask for confirmation the first time.
# AFINN may ask for confirmation the first time.
# Bing usually ships directly with tidytext.
textdata::lexicon_nrc()
textdata::lexicon_afinn()

# 4. Save local RDS copies for the app
# These files must be deployed together with app.R.

bing_lexicon <- tidytext::get_sentiments("bing")
nrc_lexicon <- tidytext::get_sentiments("nrc")
afinn_lexicon <- tidytext::get_sentiments("afinn")

readr::write_rds(bing_lexicon,  "data/bing_lexicon.rds")
readr::write_rds(nrc_lexicon,   "data/nrc_lexicon.rds")
readr::write_rds(afinn_lexicon, "data/afinn_lexicon.rds")

# 5. Check files were created
expected_files <- c(
  "data/bing_lexicon.rds",
  "data/nrc_lexicon.rds",
  "data/afinn_lexicon.rds"
)

missing_files <- expected_files[!file.exists(expected_files)]

if (length(missing_files) > 0) {
  stop(
    "Some lexicon files were not created:\n",
    paste(missing_files, collapse = "\n")
  )
}

message("Lexicon preparation complete.")
message("Created files:")
message(paste(expected_files, collapse = "\n"))