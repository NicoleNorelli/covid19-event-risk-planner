#####################################################################
# COVID-19 Event Risk Assessment Planning Tool
# - preparing daily maps for the fixed event sizes
# Maps by Seolha Lee (seolha.lee@gatehc.edu)
# Aroon Chande <mail@aroonchande.com> <achande@ihrc.com>
#####################################################################
library(dplyr)
library(ggplot2)
library(ggpubr)
library(ggrepel)
library(ggthemes)
library(jsonlite)
library(leaflet)
library(leaflet.extras)
library(lubridate)
library(mapview)
library(matlab)
library(RCurl)
library(rtweet)
library(sf)
library(withr)
library(htmlwidgets)
library(httr)
library(stringr)
library(tidyverse)
Sys.setenv(PATH = with_path("/projects/covid19/bin", Sys.getenv("PATH")))



get_token()

args <- commandArgs(trailingOnly = TRUE)
current_time <- args[1]

dataQueryUK <- function(date) {
  dataURL <- paste0("https://api.coronavirus.data.gov.uk/v1/data?filters=areaType=utla;date=", date, '&structure={"date":"date","code":"areaCode","cases":"cumCasesBySpecimenDate"}')
  response <- httr::GET(
    url = dataURL,
    timeout(10)
  )
  if (response$status_code >= 400) {
    err_msg <- httr::http_status(response)
    stop(err_msg)
  }
  # Convert response from binary to JSON:
  json_text <- content(response, "text")
  data <- jsonlite::fromJSON(json_text)$data %>%
    mutate(date = as_date(date))
  return(data)
}

getDataUK <- function() {
  cur_date <- ymd(gsub("-", "", Sys.Date())) - 1
  past_date <- ymd(cur_date) - 14

  data_past <- dataQueryUK(past_date)
  data_cur <- dataQueryUK(cur_date)
  for (i in c(1:13)) {
    data_cur <- data_cur %>% rbind(dataQueryUK(cur_date - i))
  }
  data_cur <- data_cur %>%
    group_by(code) %>%
    dplyr::summarise(date = first(date), cases = first(cases), n = n())

  uk_geom <<- st_read("https://opendata.arcgis.com/datasets/b216b4c8a4e74f6fb692a1785255d777_0.geojson", stringsAsFactors = FALSE) %>%
    rename(code = ctyua19cd, name = ctyua19nm)
  pop <- read.csv("map_data/uk_pop.csv", stringsAsFactors = FALSE) %>% select(-c("name"))

  uk_data_join <<- data_cur %>%
    inner_join(data_past, by = "code", suffix = c("", "_past")) %>%
    inner_join(pop, by = c("code"))
  uk_pal <<- colorBin("YlOrRd", bins = c(0, 1, 25, 50, 75, 99, 100))
  uk_legendlabs <<- c("< 1", " 1-25", "25-50", "50-75", "75-99", "> 99", "No or missing data")
}

# Create mouse-over labels
maplabsUK <- function(riskData) {
  riskData <- riskData %>%
    mutate(risk = case_when(
      risk == 100 ~ "> 99",
      risk == 0 ~ "< 1",
      is.na(risk) ~ "No data",
      TRUE ~ as.character(risk)
    )) %>%
    mutate(country = case_when(
      startsWith(code, "E") ~ "England",
      startsWith(code, "N") ~ "Northern Ireland",
      startsWith(code, "W") ~ "Wales",
      startsWith(code, "S") ~ "Scotland",
      TRUE ~ ""
    )) %>%
    mutate(name = case_when(
      name == "Kingston upon Hull, City of" ~ "Kingston upon Hull",
      name == "Herefordshire, County of" ~ "Herefordshire",
      name == "Bristol, City of" ~ "Bristol",
      TRUE ~ name
    ))
  labels <- paste0(
    "<strong>", paste0(riskData$name, ", ", riskData$country), "</strong><br/>",
    "Current Risk Level: <b>", riskData$risk, ifelse(riskData$risk == "No data", "", " &#37;"), "</b><br/>",
    "Latest Update: ", riskData$date
  ) %>% lapply(htmltools::HTML)
  return(labels)
}

getDataSwiss <- function() {
  dataurl <- getURL("https://raw.githubusercontent.com/openZH/covid_19/master/COVID19_Fallzahlen_CH_total_v2.csv") # date, abbreviation_canton_and_fl, ncumul_conf
  data <- read.csv(text = dataurl, stringsAsFactors = FALSE) %>%
    mutate(date = as_date(date)) %>%
    arrange(desc(date)) %>%
    filter(!is.na(ncumul_conf)) %>%
    select(date = date, code = abbreviation_canton_and_fl, cases = ncumul_conf)
  swiss_geom <<- st_read("https://gist.githubusercontent.com/mbostock/4207744/raw/3232c7558742bab53227e242a437f64ae4c58d9e/readme-swiss.json")
  pop <- read.csv("map_data/swiss_canton_pop.csv", stringsAsFactors = FALSE)

  cur_date <- ymd(gsub("-", "", Sys.Date())) - 1
  past_date <- ymd(cur_date) - 14
  data_cur <<- data %>%
    group_by(code) %>%
    summarise(code = first(code), cases = first(cases), date = first(date)) %>%
    as.data.frame()
  data_past <- data %>%
    filter(date <= past_date) %>%
    group_by(code) %>%
    summarise(code = first(code), cases = first(cases), date = first(date)) %>%
    as.data.frame()
  swiss_data_join <<- data_cur %>%
    inner_join(data_past, by = "code", suffix = c("", "_past")) %>%
    inner_join(pop, by = c("code")) %>%
    mutate(n = date - date_past) %>%
    select(-c("name"))
  swiss_pal <<- colorBin("YlOrRd", bins = c(0, 1, 25, 50, 75, 99, 100))
  swiss_legendlabs <<- c("< 1", " 1-25", "25-50", "50-75", "75-99", "> 99", "No or missing data")
}

# Create mouse-over labels
maplabsSwiss <- function(riskData) {
  riskData <- riskData %>%
    mutate(risk = case_when(
      risk == 100 ~ "> 99",
      risk == 0 ~ "< 1",
      is.na(risk) ~ "No data",
      TRUE ~ as.character(risk)
    ))
  labels <- paste0(
    "<strong>", paste0("Canton of ", riskData$name), "</strong><br/>",
    "Current Risk Level: <b>", riskData$risk, ifelse(riskData$risk == "No data", "", "&#37;"), "</b><br/>",
    "Latest Update: ", substr(riskData$date, 1, 10)
  ) %>% lapply(htmltools::HTML)
  return(labels)
}

dataQueryItaly <- function(date) {
  data <- read.csv(text = getURL(paste0("https://raw.githubusercontent.com/pcm-dpc/COVID-19/master/dati-province/dpc-covid19-ita-province-", str_replace_all(as.character(date), "-", ""), ".csv")), stringsAsFactors = FALSE) %>%
    select(date = data, region = denominazione_regione, province = denominazione_provincia, code = codice_provincia, cases = totale_casi)
  return(data)
}

getDataItaly <- function() {
  # italy: need to download data_cur and data_past respectively
  cur_date <- ymd(gsub("-", "", Sys.Date())) - 1
  past_date <- ymd(cur_date) - 14

  data_past <- dataQueryItaly(past_date) %>%
    select(date, code, cases) # date, abbreviation_canton_and_fl, ncumul_conf
  data_cur <- dataQueryItaly(cur_date)
  for (i in c(1:13)) {
    data_cur <- data_cur %>% rbind(dataQueryItaly(cur_date - i))
  }
  data_cur <- data_cur %>%
    group_by(code) %>%
    dplyr::summarise(date = first(date), cases = first(cases), region = first(region), province = first(province), n = n())

  italy_geom <<- st_read("map_data/italy_simpler.geojson")
  pop <- read.csv("map_data/italy_pop.csv", stringsAsFactors = FALSE)

  italy_data_join <<- data_cur %>%
    inner_join(data_past, by = "code", suffix = c("", "_past")) %>%
    inner_join(pop, by = c("code"))

  italy_pal <<- colorBin("YlOrRd", bins = c(0, 1, 25, 50, 75, 99, 100))
  italy_legendlabs <<- c("< 1", " 1-25", "25-50", "50-75", "75-99", "> 99", "No or missing data")
}

# Create mouse-over labels
maplabsItaly <- function(riskData) {
  riskData <- riskData %>%
    mutate(risk = case_when(
      risk == 100 ~ "> 99",
      risk == 0 ~ "< 1",
      is.na(risk) ~ "No data",
      TRUE ~ as.character(risk)
    ))
  labels <- paste0(
    "<strong>", paste0(riskData$name, ", ", riskData$region), "</strong><br/>",
    "Current Risk Level: <b>", riskData$risk, ifelse(riskData$risk == "No data", "", " &#37;"), "</b><br/>",
    "Latest Update: ", substr(riskData$date, 1, 10)
  ) %>% lapply(htmltools::HTML)
  return(labels)
}

# Calculate risk
calc_risk <- function(I, g, pop) {
  p_I <- I / pop
  r <- 1 - (1 - p_I)**g
  return(round(r * 100, 1))
}


######## Create and save daily map widgets ########

event_size <<- c(10, 25, 50, 100, 500, 1000, 5000, 10000)
asc_bias_list <<- c(5, 10)

getDataUK()

getDataSwiss()

getDataItaly()

for (asc_bias in asc_bias_list) {


  uk_data_Nr <- uk_data_join %>% mutate(Nr = (cases - cases_past) * asc_bias)
  italy_data_Nr <- italy_data_join %>% mutate(Nr = (cases - cases_past) * asc_bias)
  swiss_data_Nr <- swiss_data_join %>% mutate(Nr = (cases - cases_past) * asc_bias)

  for (size in event_size){
    uk_riskdt <- uk_data_Nr %>%
      mutate(risk = if_else(Nr > 10, round(calc_risk(Nr, size, pop)), 0))

    uk_riskdt_map <- uk_geom %>% left_join(uk_riskdt, by = c("code"))


    italy_riskdt <- italy_data_Nr %>%
      mutate(risk = if_else(Nr > 10, round(calc_risk(Nr, size, pop)), 0))

    italy_riskdt_map <- italy_geom %>% left_join(italy_riskdt, by = c("prov_istat_code_num" = "code"))


    swiss_riskdt <- swiss_data_Nr %>%
      mutate(risk = if_else(Nr > 10, round(calc_risk(Nr, size, pop)), 0))

    swiss_riskdt_map <- swiss_geom %>% left_join(swiss_riskdt, by = c("id" = "code"))


    map <- leaflet() %>%
      addProviderTiles(providers$CartoDB.Positron) %>%
      # setView(lat = 37.1, lng = -95.7, zoom = 4) %>%
      # fitBounds(7.5, 47.5, 9, 46) %>%
      addPolygons(
        data = swiss_riskdt_map,
        color = "#444444", weight = 0.2, smoothFactor = 0.1,
        opacity = 1.0, fillOpacity = 0.7,
        fillColor = ~ swiss_pal(risk),
        highlight = highlightOptions(weight = 1),
        label = maplabsSwiss(swiss_riskdt_map)
      ) %>%
      addPolygons(
        data = uk_riskdt_map,
        color = "#444444", weight = 0.2, smoothFactor = 0.1,
        opacity = 1.0, fillOpacity = 0.7,
        fillColor = ~ uk_pal(risk),
        highlight = highlightOptions(weight = 1),
        label = maplabsUK(uk_riskdt_map)
      ) %>%
      addLegend(
        data = uk_riskdt_map,
        position = "topright", pal = uk_pal, values = ~risk,
        title = "Risk Level (%)",
        opacity = 0.7,
        labFormat = function(type, cuts, p) {
          paste0(uk_legendlabs)
        }
      ) %>%
      addPolygons(
        data = italy_riskdt_map,
        color = "#444444", weight = 0.2, smoothFactor = 0.1,
        opacity = 1.0, fillOpacity = 0.7,
        fillColor = ~ italy_pal(risk),
        highlight = highlightOptions(weight = 1),
        label = maplabsItaly(italy_riskdt_map)
      ) %>%
      addEasyButton(easyButton(
        icon = "fa-crosshairs fa-lg", title = "Locate Me",
        onClick = JS("function(btn, map){ map.locate({setView: true, maxZoom: 7});}")
      ))
    map$dependencies[[1]]$src[1] <- "/srv/shiny-server/map_data/"
    mapshot(map, url = file.path(getwd(), "www", paste0("eu_", asc_bias, "_", size, ".html")))
  }
}