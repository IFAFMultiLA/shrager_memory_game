# Run this script as `Rscript answerchecking_check.R <LANGUAGE_CODE>` where "<LANGUAGE_CODE>" is one of the languages
# for which there is a default session and answer-checking data (currently "en" or "de").

library(here)
library(yaml)

source(here('..', 'common.R'))

args <- commandArgs(trailingOnly = TRUE)

if (length(args) == 0) {
    lang <- "en"
    print("no language argument given – using default language 'en'")
} else {
    lang <- args[1]
    print(sprintf("using data for language '%s'", lang))
}

questiondef <- read_yaml(here("templates", sprintf("default_session_%s.yaml", lang)))$questions
questions <- sapply(questiondef, function(item) {item$q})

checkdat <- read.csv(here(sprintf("answerchecking_data_%s.csv", lang)), header = FALSE)
stopifnot(nrow(checkdat) > 1)   # there must be at least two rows of data

check_q <- trimws(checkdat[1, ])
missing_q <- setdiff(questions, check_q)

if (length(missing_q) > 0) {
    warning(sprintf("the following questions are missing from the answer-checking dataset: %s",
                    paste(missing_q, collapse = "; ")))
}

check_question_answers <- function(i) {
    q <- trimws(checkdat[1, i])
    a <- trimws(checkdat[2:nrow(checkdat), i])
    a <- a[a != ""]

    if (length(a) == 0) {
        warning(sprintf("no answer samples for question '%s'", q))
        return(logical(0))
    }

    i_def <- which(q == questions)

    if (length(i_def) != 1) {
        return(logical(0))
    }

    sapply(a, check_answer, questiondef = questiondef[[i_def]])
}

results <- lapply(1:ncol(checkdat), check_question_answers)

n_q_failed <- 0
n_a_failed <- 0
for (i in 1:ncol(checkdat)) {
    q <- trimws(checkdat[1, i])
    print(paste0(i, ". ", q))

    qres <- results[[i]]
    if (all(qres)) {
        print("> all correct")
    } else {
        n_q_failed <- n_q_failed + 1
        n_a_failed <- n_a_failed + sum(!qres)
        wrong <- names(qres)[!qres]
        print(paste0("> failed for: ", paste(wrong, collapse = "; ")))
    }
}

print(sprintf("%d out of %d questions failed with %d failed answer samples in total.",
              n_q_failed, ncol(checkdat), n_a_failed))
