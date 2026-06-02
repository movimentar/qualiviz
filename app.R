# app.R

required_packages <- c(
  "shiny", "bslib", "readxl", "readr", "dplyr", "stringr", "tibble",
  "DT", "ggplot2", "quanteda", "quanteda.textplots", "quanteda.textstats",
  "tidytext", "textdata", "memoise", "shinycssloaders", "httr2", "jsonlite",
  "RColorBrewer", "colourpicker", "markdown", "htmltools"
)

missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0) {
  stop(
    "Please install missing packages first:\n",
    paste0("install.packages(c(", paste(shQuote(missing_packages), collapse = ", "), "))")
  )
}

invisible(lapply(required_packages, library, character.only = TRUE))

GEMINI_API_KEY <- Sys.getenv("GEMINI_API_KEY")
GA_MEASUREMENT_ID <- Sys.getenv("GA_MEASUREMENT_ID")
GEMINI_MODEL <- Sys.getenv("GEMINI_MODEL", unset = "gemini-2.5-flash")

theme_app <- bslib::bs_theme(
  version = 5,
  bootswatch = "flatly",
  primary = "#5E9F45",
  secondary = "#3E6394",
  success = "#5E9F45",
  info = "#3E6394",
  bg = "#F7FAF6",
  fg = "#1F2D3A"
)

help_tip <- function(label, tip) {
  bslib::tooltip(
    shiny::tags$span(label, shiny::icon("circle-question"), style = "font-weight: 600;"),
    tip,
    placement = "right"
  )
}

language_choices <- c(
  "English" = "en",
  "French" = "fr",
  "Portuguese" = "pt",
  "Spanish" = "es",
  "German" = "de",
  "Italian" = "it",
  "Dutch" = "nl",
  "Arabic" = "ar",
  "No automatic stopwords" = "none"
)

get_auto_stopwords <- function(lang) {
  if (is.null(lang) || lang == "none") return(character())
  tryCatch(quanteda::stopwords(lang), error = function(e) character())
}

as_text_vector <- function(x) {
  if (is.null(x)) return(character())

  if (is.list(x) && !is.data.frame(x)) {
    x <- vapply(x, function(z) paste(as.character(z), collapse = " "), character(1))
  } else {
    x <- as.character(x)
  }

  x <- stringr::str_squish(x)
  x <- x[!is.na(x) & nzchar(x)]
  x
}

looks_like_text <- function(x) {
  txt <- as_text_vector(x)
  if (length(txt) == 0) return(FALSE)

  alpha_share <- mean(stringr::str_detect(txt, "[A-Za-zÀ-ÿ]"), na.rm = TRUE)
  mean_chars <- mean(nchar(txt), na.rm = TRUE)

  isTRUE(alpha_share >= 0.2 && mean_chars >= 3)
}

short_names <- function(nms, max_len = 34) {
  out <- ifelse(nchar(nms) > max_len, paste0(substr(nms, 1, max_len - 3), "..."), nms)
  make.unique(out, sep = "_")
}

preview_data <- function(dat) {
  out <- dat
  names(out) <- short_names(names(out))
  out
}

parse_pasted_data <- function(txt) {
  if (!nzchar(txt)) stop("Paste text or upload a file.")

  readr::read_delim(
    I(txt),
    delim = "\t",
    show_col_types = FALSE,
    trim_ws = TRUE,
    name_repair = "unique"
  )
}

read_uploaded_file <- function(path, ext) {
  switch(
    ext,
    xlsx = readxl::read_excel(path, .name_repair = "unique"),
    xls  = readxl::read_excel(path, .name_repair = "unique"),
    csv  = readr::read_csv(path, show_col_types = FALSE, name_repair = "unique"),
    tsv  = readr::read_tsv(path, show_col_types = FALSE, name_repair = "unique"),
    stop("Unsupported file type. Please use .xlsx, .xls, .csv, or .tsv.")
  )
}

column_title_stopwords <- function(text_col) {
  text_col |>
    stringr::str_replace_all("[^A-Za-zÀ-ÿ]+", " ") |>
    stringr::str_to_lower() |>
    stringr::str_split("\\s+") |>
    unlist() |>
    stringr::str_trim() |>
    (\(x) x[nzchar(x) & nchar(x) > 2])()
}

get_wordcloud_colors <- function(input) {
  if (input$palette_source == "brewer") {
    info <- RColorBrewer::brewer.pal.info
    max_n <- info[input$brewer_palette, "maxcolors"]
    n <- min(input$brewer_n, max_n)
    RColorBrewer::brewer.pal(n, input$brewer_palette)
  } else if (input$palette_source == "wes" && requireNamespace("wesanderson", quietly = TRUE)) {
    wesanderson::wes_palette(input$wes_palette, n = input$wes_n, type = "continuous")
  } else if (input$palette_source == "picker") {
    c(input$wc_color_1, input$wc_color_2, input$wc_color_3, input$wc_color_4)
  } else {
    input$word_colors |>
      stringr::str_split(",") |>
      unlist() |>
      stringr::str_trim()
  }
}

scale_network_labels <- function(freq, min_size = 3, max_size = 9) {
  freq <- log1p(freq)

  if (length(unique(freq)) == 1) {
    return(rep((min_size + max_size) / 2, length(freq)))
  }

  min_size + (freq - min(freq)) / (max(freq) - min(freq)) * (max_size - min_size)
}

load_sentiment_lexicon <- function(method) {
  file_name <- paste0(method, "_lexicon.rds")

  possible_paths <- c(
    file.path("data", file_name),
    file.path("qualiviz", "data", file_name),
    file.path(getwd(), "data", file_name),
    file.path(getwd(), "qualiviz", "data", file_name)
  )

  existing_path <- possible_paths[file.exists(possible_paths)][1]

  if (is.na(existing_path)) {
    stop(
      "The ", method, " sentiment lexicon is not available.\n\n",
      "Expected one of these paths:\n",
      paste(possible_paths, collapse = "\n"), "\n\n",
      "Current working directory is:\n",
      getwd()
    )
  }

  readr::read_rds(existing_path)
}

make_text_objects <- memoise::memoise(function(
  data,
  text_col,
  lang = "en",
  custom_stopwords = "",
  remove_title_words = TRUE
) {
  txt <- as_text_vector(data[[text_col]])

  if (length(txt) == 0) {
    stop("The selected column does not contain usable text.")
  }

  extra_stop <- custom_stopwords |>
    stringr::str_split(",|\\n|;") |>
    unlist() |>
    stringr::str_trim() |>
    stringr::str_to_lower()

  extra_stop <- extra_stop[extra_stop != ""]

  title_stop <- if (isTRUE(remove_title_words)) column_title_stopwords(text_col) else character()

  stop_words <- unique(c(
    get_auto_stopwords(lang),
    extra_stop,
    title_stop
  ))

  corp <- quanteda::corpus(txt)

  toks <- corp |>
    quanteda::tokens(
      remove_punct = TRUE,
      remove_symbols = TRUE,
      remove_numbers = TRUE
    ) |>
    quanteda::tokens_tolower()

  if (length(stop_words) > 0) {
    toks <- quanteda::tokens_remove(toks, pattern = stop_words, valuetype = "fixed")
  }

  list(corpus = corp, tokens = toks, dfm = quanteda::dfm(toks))
})

tidy_words <- function(data, text_col) {
  txt <- as_text_vector(data[[text_col]])

  if (length(txt) == 0) {
    stop("The selected column does not contain usable text.")
  }

  tibble::tibble(.doc_id = seq_along(txt), text = txt) |>
    tidytext::unnest_tokens(word, text)
}

sentiment_bing <- function(data, text_col) {
  tidy_words(data, text_col) |>
    dplyr::inner_join(
      load_sentiment_lexicon("bing"),
      by = "word",
      relationship = "many-to-many"
    )
}

sentiment_nrc <- function(data, text_col) {
  tidy_words(data, text_col) |>
    dplyr::inner_join(
      load_sentiment_lexicon("nrc"),
      by = "word",
      relationship = "many-to-many"
    )
}

sentiment_afinn <- function(data, text_col) {
  tidy_words(data, text_col) |>
    dplyr::inner_join(
      load_sentiment_lexicon("afinn"),
      by = "word",
      relationship = "many-to-many"
    )
}

base_plot_theme <- function() {
  ggplot2::theme_minimal(base_size = 17) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(size = 22, face = "bold"),
      plot.subtitle = ggplot2::element_text(size = 16),
      axis.title = ggplot2::element_text(size = 18),
      axis.text = ggplot2::element_text(size = 16),
      axis.text.y = ggplot2::element_text(size = 17),
      strip.text = ggplot2::element_text(size = 16, face = "bold")
    )
}

sentiment_palette <- c(
  positive = "#1A9850",
  negative = "#D73027",
  anger = "#D73027",
  anticipation = "#FDAE61",
  disgust = "#7B3294",
  fear = "#542788",
  joy = "#66BD63",
  sadness = "#4575B4",
  surprise = "#FEE08B",
  trust = "#1A9850"
)

ga_script <- function(measurement_id) {
  if (!nzchar(measurement_id)) return(NULL)

  shiny::tagList(
    shiny::tags$script(htmltools::HTML(sprintf("
      window.dataLayer = window.dataLayer || [];
      function gtag(){dataLayer.push(arguments);}

      gtag('consent', 'default', {
        'analytics_storage': 'denied',
        'ad_storage': 'denied',
        'ad_user_data': 'denied',
        'ad_personalization': 'denied'
      });

      gtag('js', new Date());
      gtag('config', '%s', { send_page_view: false });

      function qualivizAcceptAnalytics() {
        localStorage.setItem('qualiviz_cookie_consent', 'accepted');
        gtag('consent', 'update', { 'analytics_storage': 'granted' });
        gtag('event', 'page_view', {
          page_title: 'QualiViz',
          page_location: window.location.href
        });
        var banner = document.getElementById('cookie-consent-banner');
        if (banner) banner.style.display = 'none';
      }

      function qualivizDeclineAnalytics() {
        localStorage.setItem('qualiviz_cookie_consent', 'declined');
        gtag('consent', 'update', { 'analytics_storage': 'denied' });
        var banner = document.getElementById('cookie-consent-banner');
        if (banner) banner.style.display = 'none';
      }

      function qualivizTrack(eventName, params = {}) {
        if (localStorage.getItem('qualiviz_cookie_consent') === 'accepted') {
          gtag('event', eventName, params);
        }
      }

      document.addEventListener('DOMContentLoaded', function() {
        var consent = localStorage.getItem('qualiviz_cookie_consent');

        if (consent === 'accepted') {
          gtag('consent', 'update', { 'analytics_storage': 'granted' });
          gtag('event', 'page_view', {
            page_title: 'QualiViz',
            page_location: window.location.href
          });
        } else if (consent === 'declined') {
          gtag('consent', 'update', { 'analytics_storage': 'denied' });
        } else {
          var banner = document.getElementById('cookie-consent-banner');
          if (banner) banner.style.display = 'block';
        }
      });

      document.addEventListener('click', function(e) {
        var tab = e.target.closest('[data-bs-toggle=\"tab\"]');
        if (tab && tab.textContent) {
          qualivizTrack('tab_view', { tab_name: tab.textContent.trim() });
        }
      });

      if (window.Shiny) {
        Shiny.addCustomMessageHandler('track_event', function(message) {
          qualivizTrack(message.event, message.params || {});
        });
      } else {
        document.addEventListener('shiny:connected', function() {
          Shiny.addCustomMessageHandler('track_event', function(message) {
            qualivizTrack(message.event, message.params || {});
          });
        });
      }
    ", measurement_id))),
    shiny::tags$script(
      async = NA,
      src = paste0("https://www.googletagmanager.com/gtag/js?id=", measurement_id)
    )
  )
}

cookie_banner <- shiny::div(
  id = "cookie-consent-banner",
  shiny::h4("Privacy and analytics", style = "color:#24466F; margin-top:0;"),
  shiny::p(
    "QualiViz uses optional Google Analytics cookies to understand anonymous usage patterns, such as which tabs and buttons are used. ",
    "This helps us improve the app. We do not send uploaded files, text responses, column names, generated visuals, AI summaries, or AI prompts to Google Analytics."
  ),
  shiny::p(
    "Uploaded data and generated visuals are processed only for your current app session and are not intentionally stored by QualiViz. ",
    "Please avoid uploading personal, confidential, or sensitive data unless you are authorised to do so."
  ),
  shiny::div(
    style = "display:flex; gap:10px; flex-wrap:wrap;",
    shiny::tags$button(
      "Accept analytics cookies",
      class = "btn btn-success",
      onclick = "qualivizAcceptAnalytics();"
    ),
    shiny::tags$button(
      "Decline",
      class = "btn btn-outline-secondary",
      onclick = "qualivizDeclineAnalytics();"
    ),
    shiny::tags$a(
      "Learn more about movimentar",
      href = "https://movimentar.eu",
      target = "_blank",
      class = "btn btn-link"
    )
  )
)

gemini_summarise_text <- function(data, text_col, api_key, model = "gemini-2.5-flash") {
  if (!nzchar(api_key)) {
    return("Gemini API key is not available. Add `GEMINI_API_KEY` to your `.Renviron` file and restart R.")
  }

  text_values <- as_text_vector(data[[text_col]])

  if (length(text_values) == 0) {
    return("The selected column does not contain usable text.")
  }

  sample_text <- paste(head(text_values, 150), collapse = "\n")

  prompt <- paste(
    "You are supporting qualitative data analysis in a professional public Shiny app called QualiViz.",
    "Write a concise research-oriented summary in clean Markdown only.",
    "Do not include a preamble such as 'Here is...' and do not include horizontal rules.",
    "Use the following structure exactly:",
    "",
    "## Summary",
    "",
    "### Main themes",
    "- ...",
    "",
    "### Positive signals",
    "- ...",
    "",
    "### Concerns or improvement opportunities",
    "- ...",
    "",
    "### Suggested qualitative coding categories",
    "- **Category name:** explanation",
    "",
    "### Caution",
    "One short paragraph about the limits of automated NLP and the need for human interpretation.",
    "",
    "Text sample:",
    sample_text,
    sep = "\n"
  )

  endpoint <- paste0(
    "https://generativelanguage.googleapis.com/v1beta/models/",
    model,
    ":generateContent"
  )

  body <- list(contents = list(list(parts = list(list(text = prompt)))))

  response <- httr2::request(endpoint) |>
    httr2::req_url_query(key = api_key) |>
    httr2::req_headers("Content-Type" = "application/json") |>
    httr2::req_body_json(body) |>
    httr2::req_timeout(60) |>
    httr2::req_perform()

  parsed <- httr2::resp_body_json(response, simplifyVector = FALSE)
  out <- parsed$candidates[[1]]$content$parts[[1]]$text

  if (is.null(out) || !nzchar(out)) {
    "Gemini returned an empty response."
  } else {
    out |>
      stringr::str_replace("^Here is.*?\\n+", "") |>
      stringr::str_replace_all("^---\\s*$", "")
  }
}

render_markdown_html <- function(x) {
  htmltools::HTML(markdown::markdownToHTML(text = x, fragment.only = TRUE))
}

ui <- shiny::tagList(
  shiny::tags$head(
    shiny::tags$link(rel = "stylesheet", type = "text/css", href = "custom.css"),
    ga_script(GA_MEASUREMENT_ID)
  ),

  cookie_banner,

  bslib::page_sidebar(
    title = NULL,
    theme = theme_app,

    sidebar = bslib::sidebar(
      width = 400,

      shiny::div(
        class = "sidebar-brand",
        shiny::h1("QualiViz"),
        shiny::p("Qualitative text analysis by movimentar GmbH"),
        shiny::tags$a(
          href = "https://movimentar.eu",
          target = "_blank",
          shiny::tags$img(
            src = "https://movimentar.eu/wp-content/uploads/2019/08/movimentar_logo_transparent.png"
          )
        )
      ),

      shiny::h5("1. Load data"),

      shiny::fileInput(
        "file",
        help_tip("Upload Excel / CSV / TSV", "Upload a KoboToolbox export or another table. QualiViz will detect columns that look like text."),
        accept = c(".xlsx", ".xls", ".csv", ".tsv")
      ),

      shiny::textAreaInput(
        "paste_data",
        help_tip("Or paste a tab-delimited table", "Paste a table copied from Excel or Google Sheets. The first row should contain column names."),
        placeholder = "id\tcomment\n1\tThis app is useful\n2\tThe service was slow",
        rows = 6
      ),

      shiny::actionButton(
        "use_paste",
        "Use pasted table",
        class = "btn-primary",
        onclick = "qualivizTrack('use_pasted_table');"
      ),

      shiny::hr(),

      shiny::h5("2. Text settings"),
      shiny::uiOutput("text_col_ui"),

      shiny::selectInput(
        "text_language",
        help_tip("Text language", "Used to automatically remove common stopwords in the selected language."),
        choices = language_choices,
        selected = "en"
      ),

      shiny::checkboxInput(
        "remove_title_words",
        help_tip("Remove words from question title", "Useful for KoboToolbox exports where the column name contains the survey question."),
        value = TRUE
      ),

      shiny::textAreaInput(
        "custom_stopwords",
        help_tip("Extra stopwords to remove", "Words entered here are removed in addition to automatic language stopwords."),
        value = "nil, none, nothing",
        rows = 3
      ),

      shiny::sliderInput("max_words", help_tip("Number of words", "Maximum number of words to display."), 20, 300, 100),
      shiny::sliderInput("min_count", help_tip("Minimum word count", "Words appearing fewer times than this are removed."), 1, 20, 3),
      shiny::sliderInput("min_size", help_tip("Minimum word size", "Smallest word-cloud word size."), 0.3, 3, 0.8),
      shiny::sliderInput("max_size", help_tip("Maximum word size", "Largest word-cloud word size."), 2, 12, 5),

      shiny::selectInput(
        "palette_source",
        help_tip("Word cloud color mode", "Choose ColorBrewer, Wes Anderson, color pickers, or manual hex codes."),
        choices = c(
          "ColorBrewer palette" = "brewer",
          "Wes Anderson palette" = "wes",
          "Color pickers" = "picker",
          "Manual hex codes" = "manual"
        ),
        selected = "brewer"
      ),

      shiny::conditionalPanel(
        condition = "input.palette_source == 'brewer'",
        shiny::selectInput(
          "brewer_palette",
          help_tip("ColorBrewer palette", "Set2, Dark2, and Paired are usually clear."),
          choices = rownames(RColorBrewer::brewer.pal.info),
          selected = "Set2"
        ),
        shiny::sliderInput("brewer_n", "Number of colors", min = 3, max = 9, value = 5)
      ),

      shiny::conditionalPanel(
        condition = "input.palette_source == 'wes'",
        shiny::selectInput(
          "wes_palette",
          help_tip("Wes Anderson palette", "Requires the {wesanderson} package."),
          choices = c(
            "Darjeeling1", "Darjeeling2", "GrandBudapest1", "GrandBudapest2",
            "Moonrise1", "Moonrise2", "Moonrise3", "Royal1", "Royal2",
            "Zissou1", "FantasticFox1", "Cavalcanti1"
          ),
          selected = "Zissou1"
        ),
        shiny::sliderInput("wes_n", "Number of colors", min = 3, max = 8, value = 5)
      ),

      shiny::conditionalPanel(
        condition = "input.palette_source == 'picker'",
        colourpicker::colourInput("wc_color_1", "Color 1", value = "#2C7FB8"),
        colourpicker::colourInput("wc_color_2", "Color 2", value = "#7FCDBB"),
        colourpicker::colourInput("wc_color_3", "Color 3", value = "#F03B20"),
        colourpicker::colourInput("wc_color_4", "Color 4", value = "#FEB24C")
      ),

      shiny::conditionalPanel(
        condition = "input.palette_source == 'manual'",
        shiny::textInput(
          "word_colors",
          help_tip("Manual hex colors", "Enter comma-separated hex colors."),
          "#2C7FB8,#7FCDBB,#F03B20,#FEB24C"
        )
      ),

      shiny::hr(),

      shiny::h5("3. Network settings"),

      shiny::sliderInput("network_terms", help_tip("Top terms in network", "Number of frequent words to include."), 10, 100, 35),
      shiny::sliderInput("network_min_freq", help_tip("Minimum link frequency", "Higher values simplify the network."), 0.1, 10, 0.5),
      shiny::sliderInput("edge_size", help_tip("Link width", "Visual thickness of word connections."), 0.5, 8, 2),

      shiny::checkboxInput(
        "scale_network_labels",
        help_tip("Scale network word size by frequency", "Uses a compressed log scale."),
        value = TRUE
      ),

      shiny::sliderInput("label_min_size", help_tip("Minimum network word size", "Smallest network label size."), 2, 8, 3),
      shiny::sliderInput("label_max_size", help_tip("Maximum network word size", "Largest network label size."), 4, 14, 8),
      shiny::sliderInput("label_size", help_tip("Fixed label size", "Used when scaling is disabled."), 2, 12, 5),

      shiny::hr(),

      shiny::h5("4. Sentiment settings"),

      shiny::selectInput(
        "sentiment_method",
        help_tip("Sentiment method", "Bing, NRC, and AFINN work best for English."),
        choices = c(
          "Bing: positive / negative" = "bing",
          "NRC: emotions" = "nrc",
          "AFINN: numeric score" = "afinn"
        )
      ),

      shiny::hr(),

      bslib::card(
        bslib::card_header("About QualiViz"),
        shiny::p("QualiViz is a public qualitative text-analysis tool made available by movimentar."),
        shiny::p("It helps users explore open-ended text responses through frequency tables, word clouds, text networks, sentiment views, and AI-assisted summaries."),
        shiny::p(
          class = "privacy-note",
          shiny::strong("Privacy note: "),
          "QualiViz does not intentionally store uploaded data, generated visuals, AI summaries, or AI prompts."
        ),
        shiny::tags$a("Visit movimentar.eu", href = "https://movimentar.eu", target = "_blank")
      ),

      bslib::card(
        bslib::card_header("Methods and credits"),
        shiny::p("QualiViz uses open-source R packages including Shiny, bslib, quanteda, tidytext, DT, ggplot2, and related dependencies."),
        shiny::p("Sentiment analysis uses lexicon-based methods. Bing provides positive/negative sentiment, NRC provides emotion categories, and AFINN provides numeric sentiment scores."),
        shiny::p(
          shiny::strong("NRC note: "),
          "The NRC Word-Emotion Association Lexicon may require a separate licence for commercial use. Please check the original NRC terms before commercial deployment."
        ),
        shiny::p(
          shiny::strong("Interpretation note: "),
          "Lexicon-based sentiment analysis is approximate and may miss context, irony, negation, and local language nuance. Human interpretation remains essential."
        )
      )
    ),

    shiny::conditionalPanel(
      condition = "!output.data_loaded",
      bslib::card(
        class = "splash-card",
        shiny::div(
          class = "splash-inner",
          shiny::icon("file-arrow-up", class = "splash-icon"),
          shiny::h2("Welcome to QualiViz"),
          shiny::p("QualiViz helps explore open-ended qualitative responses through word clouds, text networks, sentiment analysis, frequency tables, and AI-assisted summaries."),
          shiny::p("Upload an Excel, CSV, or TSV file, or paste a table copied from Excel or Google Sheets. Then select your text column and start exploring."),
          shiny::div(
            class = "splash-steps",
            shiny::div(shiny::strong("1."), " Upload your data"),
            shiny::div(shiny::strong("2."), " Select the text column"),
            shiny::div(shiny::strong("3."), " Explore the results")
          )
        )
      )
    ),

    shiny::conditionalPanel(
      condition = "output.data_loaded",

      bslib::accordion(
        open = FALSE,

        bslib::accordion_panel(
          title = "Data preview",
          shiny::downloadButton(
            "download_data",
            "Download data",
            class = "btn-sm btn-outline-primary",
            onclick = "qualivizTrack('download_data');"
          ),
          DT::DTOutput("preview")
        ),

        bslib::accordion_panel(
          title = "Frequency table",
          shiny::downloadButton(
            "download_freq",
            "Download frequency table",
            class = "btn-sm btn-outline-primary",
            onclick = "qualivizTrack('download_frequency_table');"
          ),
          DT::DTOutput("freq_table")
        )
      ),

      bslib::navset_card_tab(
        bslib::nav_panel(
          "Word cloud",
          shiny::div(
            class = "download-row",
            shiny::downloadButton("download_wordcloud", "Download word cloud", onclick = "qualivizTrack('download_wordcloud');")
          ),
          shinycssloaders::withSpinner(shiny::plotOutput("wordcloud", height = "650px"))
        ),

        bslib::nav_panel(
          "Text network",
          shiny::div(
            class = "download-row",
            shiny::downloadButton("download_network", "Download network plot", onclick = "qualivizTrack('download_text_network');")
          ),
          shinycssloaders::withSpinner(shiny::plotOutput("network", height = "650px"))
        ),

        bslib::nav_panel(
          "Sentiment distribution",
          shiny::div(
            class = "download-row",
            shiny::downloadButton("download_sentiment_plot", "Download sentiment plot", onclick = "qualivizTrack('download_sentiment_distribution');")
          ),
          shinycssloaders::withSpinner(shiny::plotOutput("sentiment_plot", height = "560px"))
        ),

        bslib::nav_panel(
          "Sentiment words",
          shiny::div(
            class = "download-row",
            shiny::downloadButton("download_sentiment_words", "Download sentiment words plot", onclick = "qualivizTrack('download_sentiment_words');")
          ),
          shinycssloaders::withSpinner(shiny::plotOutput("sentiment_words_plot", height = "680px"))
        ),

        bslib::nav_panel(
          "Sentiment trajectory",
          shiny::div(
            class = "download-row",
            shiny::downloadButton("download_trajectory", "Download trajectory plot", onclick = "qualivizTrack('download_sentiment_trajectory');")
          ),
          shinycssloaders::withSpinner(shiny::plotOutput("sentiment_trajectory", height = "560px"))
        ),

        bslib::nav_panel(
          "Sentiment table",
          shiny::div(
            class = "download-row",
            shiny::downloadButton("download_sentiment_table", "Download sentiment table", onclick = "qualivizTrack('download_sentiment_table');")
          ),
          DT::DTOutput("sentiment_table")
        ),

        bslib::nav_panel(
          "Gemini summary",
          bslib::card(
            bslib::card_header("AI-assisted qualitative summary"),
            shiny::div(
              class = "download-row",
              bslib::tooltip(
                shiny::actionButton(
                  "run_gemini",
                  "Generate AI summary",
                  class = "btn-success",
                  onclick = "qualivizTrack('generate_ai_summary');"
                ),
                "This sends a sample of the selected text column to the Gemini API to generate an AI-assisted qualitative summary. Do not use this with sensitive or confidential data unless authorised.",
                placement = "right"
              )
            ),
            shiny::uiOutput("gemini_status"),
            shiny::div(class = "summary-box", shiny::uiOutput("gemini_summary"))
          )
        )
      )
    )
  )
)

server <- function(input, output, session) {

  pasted_data <- shiny::eventReactive(input$use_paste, parse_pasted_data(input$paste_data))

  uploaded_data <- shiny::reactive({
    shiny::req(input$file)
    ext <- tools::file_ext(input$file$name) |> tolower()
    read_uploaded_file(input$file$datapath, ext)
  })

  raw_data <- shiny::reactive({
    if (!is.null(input$file)) uploaded_data() else pasted_data()
  })

  output$data_loaded <- shiny::reactive({
    file_loaded <- !is.null(input$file)
    paste_loaded <- isTRUE(input$use_paste > 0) && nzchar(input$paste_data)
    file_loaded || paste_loaded
  })

  shiny::outputOptions(output, "data_loaded", suspendWhenHidden = FALSE)

  shiny::observeEvent(input$file, {
    session$sendCustomMessage(
      "track_event",
      list(event = "upload_file", params = list(file_type = tools::file_ext(input$file$name)))
    )
  })

  text_candidates <- shiny::reactive({
    shiny::req(raw_data())
    dat <- raw_data()
    names(dat)[vapply(dat, looks_like_text, logical(1))]
  })

  output$text_col_ui <- shiny::renderUI({
    choices <- text_candidates()

    if (length(choices) == 0) {
      return(shiny::div(
        class = "text-danger",
        shiny::strong("No usable text columns detected."),
        shiny::p("Please upload a file with at least one column containing written text.")
      ))
    }

    preferred <- "Please mention two points where we can improve our work."

    shiny::selectInput(
      "text_col",
      help_tip("Text column", "Choose the open-ended response column you want to analyse."),
      choices = choices,
      selected = if (preferred %in% choices) preferred else choices[1]
    )
  })

  selected_text_col <- shiny::reactive({
    shiny::req(input$text_col)
    shiny::req(input$text_col %in% names(raw_data()))
    input$text_col
  })

  text_objects <- shiny::reactive({
    shiny::req(raw_data(), selected_text_col())
    make_text_objects(
      raw_data(),
      selected_text_col(),
      input$text_language,
      input$custom_stopwords,
      input$remove_title_words
    )
  })

  freq_data <- shiny::reactive({
    shiny::req(text_objects())
    quanteda.textstats::textstat_frequency(text_objects()$dfm) |>
      tibble::as_tibble() |>
      dplyr::select(feature, frequency, rank)
  })

  sentiment_data <- shiny::reactive({
    shiny::req(raw_data(), selected_text_col())

    switch(
      input$sentiment_method,
      bing = sentiment_bing(raw_data(), selected_text_col()),
      nrc = sentiment_nrc(raw_data(), selected_text_col()),
      afinn = sentiment_afinn(raw_data(), selected_text_col())
    )
  })

  draw_wordcloud <- function() {
    shiny::req(text_objects())

    text_objects()$dfm |>
      quanteda::dfm_trim(min_termfreq = input$min_count) |>
      quanteda.textplots::textplot_wordcloud(
        min_size = input$min_size,
        max_size = input$max_size,
        min_count = input$min_count,
        max_words = input$max_words,
        color = get_wordcloud_colors(input),
        random_order = FALSE
      )
  }

  draw_network <- function() {
    shiny::req(text_objects())

    freq <- quanteda.textstats::textstat_frequency(text_objects()$dfm) |>
      tibble::as_tibble() |>
      dplyr::slice_max(frequency, n = input$network_terms)

    features <- freq$feature
    shiny::req(length(features) >= 2)

    fcmat <- quanteda::fcm(text_objects()$tokens, context = "window", window = 5, tri = FALSE)
    fcmat_small <- quanteda::fcm_select(fcmat, pattern = features, selection = "keep")

    label_sizes <- if (isTRUE(input$scale_network_labels)) {
      scale_network_labels(freq$frequency, min_size = input$label_min_size, max_size = input$label_max_size)
    } else {
      rep(input$label_size, length(features))
    }

    names(label_sizes) <- features

    quanteda.textplots::textplot_network(
      fcmat_small,
      min_freq = input$network_min_freq,
      edge_size = input$edge_size,
      vertex_labelsize = label_sizes,
      edge_color = "#2C7FB8",
      vertex_color = "#333333"
    )
  }

  sentiment_plot_object <- shiny::reactive({
    shiny::req(sentiment_data())

    if (input$sentiment_method == "afinn") {
      sentiment_data() |>
        dplyr::group_by(.doc_id) |>
        dplyr::summarise(score = sum(value), .groups = "drop") |>
        ggplot2::ggplot(ggplot2::aes(x = score)) +
        ggplot2::geom_histogram(bins = 30, fill = "#2C7FB8", color = "white") +
        ggplot2::labs(title = "AFINN sentiment score distribution", x = "Document sentiment score", y = "Number of documents") +
        base_plot_theme()
    } else {
      sentiment_data() |>
        dplyr::count(sentiment, sort = TRUE) |>
        dplyr::mutate(sentiment = factor(sentiment, levels = rev(sentiment))) |>
        ggplot2::ggplot(ggplot2::aes(x = sentiment, y = n, fill = sentiment)) +
        ggplot2::geom_col(width = 0.7) +
        ggplot2::coord_flip() +
        ggplot2::scale_fill_manual(values = sentiment_palette, guide = "none") +
        ggplot2::labs(title = "Sentiment / emotion distribution", x = NULL, y = "Word count") +
        base_plot_theme()
    }
  })

  sentiment_words_plot_object <- shiny::reactive({
    shiny::req(sentiment_data())

    if (input$sentiment_method == "afinn") {
      sentiment_data() |>
        dplyr::group_by(word) |>
        dplyr::summarise(score = sum(value), n = dplyr::n(), .groups = "drop") |>
        dplyr::slice_max(abs(score), n = 20) |>
        ggplot2::ggplot(ggplot2::aes(x = reorder(word, score), y = score, fill = score > 0)) +
        ggplot2::geom_col() +
        ggplot2::coord_flip() +
        ggplot2::scale_fill_manual(values = c("TRUE" = "#1A9850", "FALSE" = "#D73027"), guide = "none") +
        ggplot2::labs(title = "Top contributing AFINN words", x = NULL, y = "Total sentiment score") +
        base_plot_theme()
    } else {
      sentiment_data() |>
        dplyr::count(word, sentiment, sort = TRUE) |>
        dplyr::group_by(sentiment) |>
        dplyr::slice_max(n, n = 10) |>
        dplyr::ungroup() |>
        ggplot2::ggplot(ggplot2::aes(x = reorder(word, n), y = n, fill = sentiment)) +
        ggplot2::geom_col() +
        ggplot2::coord_flip() +
        ggplot2::facet_wrap(~ sentiment, scales = "free_y") +
        ggplot2::scale_fill_manual(values = sentiment_palette, guide = "none") +
        ggplot2::labs(title = "Top words contributing to sentiment", x = NULL, y = "Word count") +
        base_plot_theme()
    }
  })

  sentiment_trajectory_object <- shiny::reactive({
    shiny::req(raw_data(), selected_text_col())

    words <- tidy_words(raw_data(), selected_text_col()) |>
      dplyr::mutate(position = dplyr::row_number())

    if (input$sentiment_method == "afinn") {
      traj <- words |>
        dplyr::inner_join(load_sentiment_lexicon("afinn"), by = "word", relationship = "many-to-many") |>
        dplyr::mutate(bin = ceiling(position / 100)) |>
        dplyr::group_by(bin) |>
        dplyr::summarise(score = sum(value), .groups = "drop")
    } else {
      lexicon <- if (input$sentiment_method == "bing") {
        load_sentiment_lexicon("bing")
      } else {
        load_sentiment_lexicon("nrc") |>
          dplyr::filter(sentiment %in% c("positive", "negative"))
      }

      traj <- words |>
        dplyr::inner_join(lexicon, by = "word", relationship = "many-to-many") |>
        dplyr::mutate(
          value = dplyr::if_else(sentiment == "positive", 1, -1),
          bin = ceiling(position / 100)
        ) |>
        dplyr::group_by(bin) |>
        dplyr::summarise(score = sum(value), .groups = "drop")
    }

    shiny::req(nrow(traj) > 1)

    traj |>
      ggplot2::ggplot(ggplot2::aes(x = bin, y = score)) +
      ggplot2::geom_line(linewidth = 1.1, color = "#2C7FB8") +
      ggplot2::geom_point(size = 2.2, color = "#2C7FB8") +
      ggplot2::geom_hline(yintercept = 0, linetype = "dashed", color = "#D73027") +
      ggplot2::labs(
        title = "Sentiment trajectory across text",
        subtitle = "Scores aggregated every 100 words",
        x = "Text progression",
        y = "Net sentiment score"
      ) +
      base_plot_theme()
  })

  output$preview <- DT::renderDT({
    shiny::req(raw_data())
    DT::datatable(preview_data(raw_data()), options = list(pageLength = 8, scrollX = TRUE, autoWidth = TRUE))
  })

  output$freq_table <- DT::renderDT({
    shiny::req(freq_data())
    DT::datatable(freq_data(), options = list(pageLength = 10, scrollX = TRUE))
  })

  output$wordcloud <- shiny::renderPlot(draw_wordcloud())
  output$network <- shiny::renderPlot(draw_network())
  output$sentiment_plot <- shiny::renderPlot(sentiment_plot_object())
  output$sentiment_words_plot <- shiny::renderPlot(sentiment_words_plot_object())
  output$sentiment_trajectory <- shiny::renderPlot(sentiment_trajectory_object())

  output$sentiment_table <- DT::renderDT({
    DT::datatable(sentiment_data(), options = list(pageLength = 12, scrollX = TRUE))
  })

  gemini_cache_key <- shiny::reactive({
    shiny::req(raw_data(), selected_text_col())

    list(
      n_rows = nrow(raw_data()),
      n_cols = ncol(raw_data()),
      text_col = selected_text_col(),
      language = input$text_language,
      stopwords = input$custom_stopwords,
      remove_title_words = input$remove_title_words
    )
  })

  gemini_state <- shiny::reactiveValues(key = NULL, result = NULL, running = FALSE)

  shiny::observe({
    current_key <- gemini_cache_key()
    if (!identical(gemini_state$key, current_key)) gemini_state$result <- NULL
  })

  shiny::observeEvent(input$run_gemini, {
    shiny::req(raw_data(), selected_text_col())

    current_key <- gemini_cache_key()

    if (!is.null(gemini_state$result) && identical(gemini_state$key, current_key)) return()

    gemini_state$running <- TRUE

    result <- shiny::withProgress(
      message = "Generating AI summary with Gemini...",
      value = 0.5,
      {
        gemini_summarise_text(raw_data(), selected_text_col(), GEMINI_API_KEY, GEMINI_MODEL)
      }
    )

    gemini_state$key <- current_key
    gemini_state$result <- result
    gemini_state$running <- FALSE
  })

  output$gemini_status <- shiny::renderUI({
    shiny::req(raw_data(), selected_text_col())

    current_key <- gemini_cache_key()

    if (isTRUE(gemini_state$running)) {
      return(shiny::div(class = "alert alert-info", "Generating summary. Please wait..."))
    }

    if (!is.null(gemini_state$result) && identical(gemini_state$key, current_key)) {
      return(shiny::div(class = "alert alert-success", "Summary generated for the current data and selected text column."))
    }

    shiny::div(class = "alert alert-warning", "Click “Generate AI summary” to create a Gemini-assisted summary for the selected text column.")
  })

  output$gemini_summary <- shiny::renderUI({
    shiny::req(gemini_state$result)
    render_markdown_html(gemini_state$result)
  })

  output$download_data <- shiny::downloadHandler(
    filename = function() "qualiviz_data.csv",
    content = function(file) readr::write_csv(raw_data(), file)
  )

  output$download_freq <- shiny::downloadHandler(
    filename = function() "qualiviz_frequency_table.csv",
    content = function(file) readr::write_csv(freq_data(), file)
  )

  output$download_sentiment_table <- shiny::downloadHandler(
    filename = function() "qualiviz_sentiment_table.csv",
    content = function(file) readr::write_csv(sentiment_data(), file)
  )

  output$download_sentiment_plot <- shiny::downloadHandler(
    filename = function() "qualiviz_sentiment_distribution.png",
    content = function(file) ggplot2::ggsave(file, sentiment_plot_object(), width = 12, height = 7, dpi = 300)
  )

  output$download_sentiment_words <- shiny::downloadHandler(
    filename = function() "qualiviz_sentiment_words.png",
    content = function(file) ggplot2::ggsave(file, sentiment_words_plot_object(), width = 13, height = 8, dpi = 300)
  )

  output$download_trajectory <- shiny::downloadHandler(
    filename = function() "qualiviz_sentiment_trajectory.png",
    content = function(file) ggplot2::ggsave(file, sentiment_trajectory_object(), width = 12, height = 7, dpi = 300)
  )

  output$download_wordcloud <- shiny::downloadHandler(
    filename = function() "qualiviz_wordcloud.png",
    content = function(file) {
      grDevices::png(file, width = 1800, height = 1200, res = 200)
      draw_wordcloud()
      grDevices::dev.off()
    }
  )

  output$download_network <- shiny::downloadHandler(
    filename = function() "qualiviz_text_network.png",
    content = function(file) {
      grDevices::png(file, width = 1800, height = 1200, res = 200)
      draw_network()
      grDevices::dev.off()
    }
  )
}

shiny::shinyApp(ui, server)
