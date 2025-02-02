# Shrager Memory Game – participants' app.
#
# Shiny app that implements the memory game for experiment participants. Please note that there's additional JavaScript
# code in `www/custom.js` that is crucial for the functioning of this app.
#
# Author: Markus Konrad <markus.konrad@htw-berlin.de>

library(shiny)
library(here)
library(yaml)
library(stringi)
library(dplyr)
library(filelock)

# include common functions
source(here('..', 'common.R'))

SESSION_REFRESH_TIME <- 1000        # session refresh timer in milliseconds
ASSIGNMENT_MODE <- "alternating"    # group assignment mode; either "random" or "alternating"

stopifnot(ASSIGNMENT_MODE %in% c("random", "alternating"))


# helper function to get path to user data RDS file
user_data_path <- function(sess_id, user_id) {
    here(SESS_DIR, sess_id, paste0("user_", user_id, ".rds"))
}

# helper function to store user data (list object `user_data`) for user `user_id` in session `sess_id`
# and group `group`; if `update` is TRUE, loads existing user data and merges it with `user_data`
save_user_data <- function(sess_id, user_id, group, user_data, update = FALSE) {
    # print("saving user data")
    # print(user_data)

    if (update) {
        # load existing user data on update
        existing_data <- load_user_data(sess_id, user_id)
        if (is.null(existing_data)) {   # returns NULL if no user data exists; initialize w/ empty list
            existing_data <- list()
        }

        # update the existing data with new data in `user_data`
        for (k in names(user_data)) {
            existing_data[[k]] <- user_data[[k]]
        }

        # delete these keys – will be set below
        existing_data[c('user_id', 'group')] <- NULL

        user_data <- existing_data
    }

    # set user ID and group and store to RDS file
    saveRDS(c(list(user_id = user_id, group = group), user_data),
            here(SESS_DIR, sess_id, paste0("user_", user_id, ".rds")))
}

# helper function to load existing user data for user `user_id` in session `sess_id`; returns a list if data exists,
# otherwise returns NULL
load_user_data <- function(sess_id, user_id) {
    file <- user_data_path(sess_id, user_id)
    # print("loading user data")
    if (fs::file_exists(file)) {
        readRDS(file)
    } else {
        NULL
    }
}

# helper function to create an input element for survey item `item` that accepts an integer
survey_input_int <- function(item) {
    lbl <- paste0("survey_", item$label)

    args <- list(
        id = lbl,
        name = lbl,
        type = "number",
        step = "1"
    )

    if (!is.null(item$input$range)) {
        args$min <- item$range[1]
        args$max <- item$range[2]
    }

    if (!is.null(item$input$required) && item$input$required) {
        args$required <- "required"
    }

    do.call(tags$input, args)
}

# helper function to create an input element for survey item `item` that accepts a text input
survey_input_text <- function(item) {
    lbl <- paste0("survey_", item$label)

    args <- list(
        id = lbl,
        name = lbl,
        type = "text"
    )

    if (!is.null(item$input$required) && item$input$required) {
        args$required <- "required"
    }

    do.call(tags$input, args)
}

# minimal shiny app UI definition
ui <- fluidPage(
    tags$script(src = "js.cookie.min.js"),    # cookie JS library
    tags$script(src = "custom.js"),    # custom JS
    tags$link(rel = "stylesheet", type = "text/css", href = "custom.css"),   # custom CSS
    # titlePanel("Shrager Memory Game: Participant App"),
    verticalLayout(
        uiOutput("mainContent")    # all UI elements are rendered in "mainContent" dynamically
    )
)

# shiny app server definition
server <- function(input, output, session) {
    # app state
    state <- reactiveValues(
        user_id = NULL,            # user ID of the connected user
        sess_id = NULL,            # session ID of the experiment
        sess = NULL,               # session configuration (list)
        group = NULL,              # group assignment ("ctrl" or "treat" – see GROUPS)
        sess_id_was_set = FALSE,   # stores if session ID was already set
        group_was_set = FALSE,     # stores if user was already assigned to a group
        question_indices = NULL,   # stores indices into quiz questions; may be randomized if session is config. as such
        user_results = NULL,       # logical vector storing if question was answered correctly
        user_answers = NULL,       # character vector storing the answers to the quiz questions given by the participant
        survey_answers = NULL      # character vector storing the answers to the survey given by the participant
    )

    # helper function that returns TRUE when the currently selected session includes a survey, otherwise FALSE
    hasSurvey <- function() {
        state$sess$config$survey && !is.null(state$sess$survey) && length(state$sess$survey) > 0
    }

    # create a polling loop by implementing a reactive context that invalidates itself periodically
    # via `invalidateLater()` or when one of the reactive `state` variables was changed
    observe({
        # get session ID from query string in URL like ".../MGParticipant/?sess_id=XYZ"
        params <- getQueryString()
        sess_id <- params$sess_id

        # check the session ID
        if (is.null(sess_id) || !validate_id(sess_id, SESS_ID_CODE_LENGTH, expect_session_dir = TRUE)) {
            showModal(modalDialog("Invalid session ID or session ID not given.", footer = NULL))
        } else {
            # session ID is valid
            state$sess_id <- sess_id

            # schedule to re-run this context after `SESSION_REFRESH_TIME` ms
            invalidateLater(SESSION_REFRESH_TIME)

            # send the session ID to the JavaScript (JS) side (see `www/custom.js`) if it wasn't sent yet
            if (!state$sess_id_was_set) {
                session$sendCustomMessage("set_sess_id", state$sess_id);
                isolate(state$sess_id_was_set <- TRUE)
            }

            # perform group assignment if the JS side couldn't determine it from a cookie
            if (state$group_was_set && state$group == "unassigned") {
                if (ASSIGNMENT_MODE == "random") {
                    # random assignment
                    isolate(state$group <- sample(GROUPS, size = 1))
                    print(sprintf("random assignment to group '%s'", state$group))
                } else {   # ASSIGNMENT_MODE == "alternating"
                    # alternating group assignment using an RDS file that always stores the assignment send to the
                    # previous participant; the RDS file is file-locked to prevent concurrent access (see
                    # ?lock::filelock for details)
                    cur_sess_dir <- here(SESS_DIR, sess_id)

                    assignment_file <- here(cur_sess_dir, "assignments.rds")
                    if (fs::file_exists(assignment_file)) {
                        # an assignments file exists (there were assignments before)
                        lockfile <- lock(here(cur_sess_dir, "assignments.lock"))
                        g <- readRDS(assignment_file)
                        g <- (g %% 2) + 1   # alternate between 1 and 2
                        saveRDS(g, assignment_file)
                        unlock(lockfile)
                    } else {
                        # no assignments file exists – initial assignment is done randomly
                        lockfile <- lock(here(cur_sess_dir, "assignments.lock"))
                        g <- sample(1:2, size = 1)
                        saveRDS(g, assignment_file, compress = FALSE)
                        unlock(lockfile)
                    }

                    stopifnot(g %in% 1:2)

                    isolate(state$group <- GROUPS[g])
                    print(sprintf("alternating assignment to group '%s'", state$group))
                }

                # announce the group assignment to the JS side
                session$sendCustomMessage("set_group", state$group);
            }

            # load the experiment session configuration
            state$sess <- load_sess_config(state$sess_id)
        }
    })

    # actions to perform when the user ID was set from the JS side
    observeEvent(input$user_id, {
        print(paste("got user_id via JS:", input$user_id))

        if (input$user_id == "unassigned") {
            # initially, no user ID is assigned from the JS side so we will generate one here
            user_id <- NULL
            while (is.null(user_id) || fs::file_exists(here(SESS_DIR, state$sess_id, paste0(user_id, ".rds")))) {
                user_id <- stri_rand_strings(1, USER_ID_CODE_LENGTH)
            }

            isolate(state$user_id <- user_id)

            # send the user ID to the JS side
            session$sendCustomMessage("set_user_id", state$user_id);
        } else if (validate_id(input$user_id, USER_ID_CODE_LENGTH)) {
            # already got a valid user ID from the JS side (loaded from cookie)
            user_id <- input$user_id
        } else {
            # setting the user ID failed – probably a malformed ID sent from the JS side
            user_id <- NULL
        }

        # save empty user data just to claim the ID
        if (!is.null(user_id) && !fs::file_exists(user_data_path(state$sess_id, user_id))) {
            save_user_data(state$sess_id, user_id, state$group, list(user_results = NULL, user_answers = NULL))
        }

        print(paste("setting user ID to", user_id))
        state$user_id <- user_id
    })

    # actions to perform when the user was assigned to a group from the JS side; the group is either "ctrl" or "treat"
    # when the user already visited the quiz (it's loaded from a cookie); if the user first visits the quiz, it's set
    # to "unassigned" and the polling loop above will take care of the actual assignment
    observeEvent(input$group, {
        print(paste("got group via JS:", input$group))
        isolate(state$group <- input$group)   # doesn't trigger update
        state$group_was_set <- TRUE    # triggers update on change
    })


    # actions to perform when answers are submitted by the user
    observeEvent(input$submit_answers, {
        req(state$sess)
        #req(state$sess$stage == "questions")
        req(state$user_id)
        req(is.null(state$user_results) && is.null(state$user_answers))

        # check answers
        user_answers <- character(length(state$sess$questions))   # prepare vector of answers
        state$user_results <- sapply(seq_along(state$sess$questions), function(i) {
            user_answer <- trimws(input[[sprintf("answer_%s", i)]])
            # store the answer in separate vector
            user_answers[i] <<- user_answer

            # gives a logical output
            check_answer(state$sess$questions[[i]], user_answer)
        })

        # save user data for this session and user ID
        state$user_answers <- user_answers
        save_user_data(state$sess_id, state$user_id, state$group,
                       list(
                           question_indices = state$question_indices,
                           user_results = state$user_results,
                           user_answers = state$user_answers
                       )
        )
    })

    # actions to perform when survey questionaire is submitted by the user
    observeEvent(input$submit_survey, {
        req(state$sess)
        #req(state$sess$stage == "survey")
        req(state$user_id)
        req(is.null(state$survey_answers))

        # store survey answers as char. vector
        survey_answers <- sapply(state$sess$survey, function(item) {
            as.character(input[[paste0("survey_", item$label)]])
        })

        # save survey data for this session and user ID
        state$survey_answers <- survey_answers
        save_user_data(state$sess_id, state$user_id, state$group, list(survey_answers = state$survey_answers),
                       update = TRUE)
    })

    # display function for "start" stage: simply show a message
    display_start <- function() {
        div(state$sess$messages$not_started, class = "alert alert-info", style = "text-align: center")
    }

    # display function for "directions" stage: show HTML formatted game directions
    display_directions <- function() {
        msg_key <- paste0("directions_", state$group)
        directions <- state$sess$messages[[msg_key]]
        div(HTML(directions))
    }

    # display function for "questions" stage: show questions along with input fields; show already entered answers;
    # show quiz results if results are given
    display_questions <- function() {
        # load user data and store it in app state
        user_data <- load_user_data(state$sess_id, state$user_id)
        state$user_results <- user_data$user_results
        state$user_answers <- user_data$user_answers
        state$question_indices <- user_data$question_indices

        isolate({
            # generate question indices
            if (is.null(state$question_indices)) {
                state$question_indices <- seq_along(state$sess$questions)

                # optionally randomize question display order
                if (state$sess$config$randomize_questions) {
                    state$question_indices <- sample(state$question_indices)
                }
            }
        })

        # generate the list of questions along with input fields; show user input's and possibly user results when these
        # data are already given
        list_items <- lapply(state$question_indices, function(i) {
            # question definition
            item <- state$sess$questions[[i]]

            if (!is.null(state$user_results)) {
                # results are given: show user answer as "span" field (no input possible) along with quiz result
                answ <- span(
                    span(ifelse(is.null(state$user_answers), input[[sprintf("answer_%s", i)]], state$user_answers[i]),
                         style = "color: #666666"),
                    icon(ifelse(state$user_results[i], "check", "remove"),
                         style = paste("color:", ifelse(state$user_results[i], "#00AA00", "#AA0000")))
                )
            } else {
                # results are not given: show input field
                answ <- textInput(inputId = sprintf("answer_%s", i), label = NULL)
            }

            # generate HTML for this item
            tags$li(
                div(item$q),
                answ
            )
        })

        # bottom element
        if (is.null(state$user_results)) {
            # no results given yet – show submit button
            bottom_elem <- div(actionButton("submit_answers", state$sess$messages$submit, class = "btn-success"),
                               id = "submit_container")
        } else {
            # results are given – show sum of correct answers
            n_correct <- sum(state$user_results)
            bottom_elem <- p(sprintf(state$sess$messages$results_summary, n_correct),
                             style = "font-weight: bold; text-align: center")
        }

        # final HTML output
        div(
            tags$ol(list_items, id = "questions"),
            bottom_elem
        )
    }

    # display function for "survey" stage: show survey form
    display_survey <- function() {
        # load user data and store it in app state
        user_data <- load_user_data(state$sess_id, state$user_id)
        state$survey_answers <- user_data$survey_answers

        if (is.null(state$survey_answers)) {
            # no survey answers given, yet – generate the input fields for each survey item
            survey_items <- lapply(state$sess$survey, function(item) {
                survey_input_fn <- switch (item$input$type,
                    int = survey_input_int,
                    text = survey_input_text
                )

                tags$li(tags$label(item$text, `for` = paste0('survey_', item$label)), survey_input_fn(item))
            })

            # finalize the form
            div(
                tags$ol(survey_items, id = "survey"),
                div(actionButton("submit_survey", state$sess$messages$submit, class = "btn-success"),
                    id = "submit_container")
            )
        } else {
            # survey answers already given – show a message
            div(state$sess$messages$survey_ended, class = "alert alert-info", style = "text-align: center")
        }
    }

    # display function for "results" stage: show results summary
    display_results <- function() {
        # get results
        sess_data <- data_for_session(state$sess_id, survey_labels_for_session(state$sess))

        # summarize
        summ_data <- group_by(sess_data, group, .drop = FALSE) |>
            summarise(n = n(),
                      total_correct = sum(n_correct),
                      mean_correct = round(mean(n_correct), 2),
                      sd_correct = round(sd(n_correct), 2))

        # prepare for display
        msgs <- state$sess$messages

        tbl_data <- t(summ_data)
        cols <- tbl_data[1, ]
        col_own_group <- cols == state$group
        cols[col_own_group] <- sprintf(msgs$own_group, state$group)
        cols[!col_own_group] <- sprintf(msgs$other_group, cols[!col_own_group])
        colnames(tbl_data) <- cols
        tbl_data <- tbl_data[-1, ]

        rownames(tbl_data) <- c(msgs$summary_statistics_count, msgs$summary_statistics_total,
                                msgs$summary_statistics_mean, msgs$summary_statistics_std)

        list(
            h1(msgs$summary_statistics),
            p(sprintf(msgs$group_information, state$group)),
            renderTable(tbl_data, rownames = TRUE),
            div(downloadButton("downloadResults", msgs$download_data, class = "btn-info"),
                style = "text-align: center")
        )
    }

    # display function for "end" stage: show a message
    display_end <- function() {
        div(state$sess$messages$end, class = "alert alert-info", style = "text-align: center")
    }

    # render the main (and only) content, depending on the current game stage
    output$mainContent <- renderUI({
        req(state$sess)

        # determine the stage that comes after the "questions" stage: skip survey if this session doesn't include one
        post_questions_stage <- ifelse(hasSurvey(), "survey", "results")

        # issue an automatic submission for the quiz answers
        if (state$sess$stage == post_questions_stage && is.null(state$user_results)) {
            session$sendCustomMessage("autosubmit", "submit_answers")
        }

        # issue an automatic submission for the survey answers
        if (hasSurvey() && state$sess$stage == "results" && is.null(state$survey_answers)) {
            session$sendCustomMessage("autosubmit", "submit_survey")
        }

        # determine the function that is used to build the output
        display_fn <- switch (state$sess$stage,
            start = display_start,
            directions = display_directions,
            questions = display_questions,
            survey = display_survey,
            results = display_results,
            end = display_end
        )

        # run the function to build the output
        display_fn()
    })

    # download handler for experiment results
    output$downloadResults <- downloadHandler(
        filename = function() {
            req(state$sess$stage == "results")
            "results.csv"
        },
        content = function(file) {
            req(state$sess$stage == "results")

            sess_data <- data_for_session(state$sess_id, survey_labels_for_session(state$sess))
            write.csv(sess_data, file, row.names = FALSE)
        }
    )
}

# Run the application
shinyApp(ui = ui, server = server)
