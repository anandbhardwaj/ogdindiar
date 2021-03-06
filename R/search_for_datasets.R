mk_link <- . %>% paste0("https://data.gov.in", .)

generator_of_get_link <- function(x, wait = 0.25) {
  last_url_accessed <- NA_real_
  
  function(x, wait = 0.25) {
    if ( !is.na(last_url_accessed) &&
         ((diff <- as.numeric(Sys.time()) - last_url_accessed) < wait) ) {
      Sys.sleep(wait - diff)
    }
    
    #TODO: Add retry functionality here
    message('Requesting page ', x)
    ans <- read_html(x)
    
    #TODO: Replace <<- usage here
    last_url_accessed <<- as.numeric(Sys.time())
    
    ans
  }
}

get_link <- generator_of_get_link()


fill_na_if_empty <- function(x) {
  if (length(x) != 0) return(x)
  x[NA]
}

extract_resource_id <- function(api_link) {
  get_link(api_link) %>%
    html_nodes(css = 'p:nth-child(4) a') %>%
    html_attr('href') %>% 
    gsub(x = ., pattern = '.*resource_id=(.*)&api-key=YOURKEY$', replacement = '\\1')
}

extract_catalogs_from_search_result <- function(parsed_html) {
  link_nodes <- parsed_html %>% html_nodes(css = '.views-field-title a')
  
  link_data <- data.frame(name = html_text(link_nodes),
                          link = html_attr(link_nodes, 'href'),
                          stringsAsFactors = FALSE)
  
  category <- dirname(link_data$link) %>% gsub(pattern = '^/', replacement = '')
  
  link_data[category %in% 'catalog', , drop = FALSE]
}

extract_info_from_single_data_set <- function(single_data_set) {
  
  data_set_name <- single_data_set %>% html_nodes(css = '.title-content') %>% html_text
  
  granularity <- single_data_set %>%
    html_nodes(css = '.views-field-field-granularity .field-content') %>%
    html_text
  
  file_size <- single_data_set %>%
    html_nodes(css = '.download-filesize') %>%
    html_text %>% 
    gsub(x = ., pattern = '.*File Size: (.*)', replacement = '\\1')
  
  download_count <- single_data_set %>%
    html_nodes(css = '.download-counts') %>%
    html_text %>% 
    gsub(x = ., pattern = '.*Download: (.*)', replacement = '\\1') %>% 
    as.numeric
  
  res_id <- single_data_set %>%
    html_nodes(css = '.api-link') %>%
    html_attr('href') %>% 
    fill_na_if_empty %>% 
    ifelse(is.na(.), yes = ., no = extract_resource_id(.))
  
  csv_link   <- single_data_set %>% html_nodes(css = '.data-extension') %>% html_attr('href')
  ods_link   <- single_data_set %>% html_nodes(css = '.ods')            %>% html_attr('href')
  xls_link   <- single_data_set %>% html_nodes(css = '.xls')            %>% html_attr('href')
  json_link  <- single_data_set %>% html_nodes(css = '.json')           %>% html_attr('href')
  xml_link   <- single_data_set %>% html_nodes(css = '.xml')            %>% html_attr('href')
  jsonp_link <- single_data_set %>% html_nodes(css = '.jsonp')          %>% html_attr('href')
  
  reference_url <- single_data_set %>% html_nodes(css = '.ext') %>% html_attr('href')
  note <- single_data_set %>% html_nodes(css = '.ogpl-processed') %>% html_text
  
  data.frame(name             = fill_na_if_empty(data_set_name),
             granularity      = fill_na_if_empty(granularity),
             file_size        = fill_na_if_empty(file_size),
             downloads        = fill_na_if_empty(download_count),
             res_id           = res_id,
             csv              = fill_na_if_empty(csv_link),
             ods              = fill_na_if_empty(ods_link),
             xls              = fill_na_if_empty(xls_link),
             json             = fill_na_if_empty(json_link),
             xml              = fill_na_if_empty(xml_link),
             jsonp            = fill_na_if_empty(jsonp_link),
             stringsAsFactors = FALSE)
}

#' @title get data sets for a catalog
#' @description Get the list of data sets and related info for a catalog
#' @param catalog_link Link to the catalog
#' @param limit_pages Limit the number of pages that the function should request. Each page contains a list of data sets.
#' @importFrom magrittr %>%
#' @importFrom xml2 read_html
#' @importFrom rvest html_nodes html_text html_attr
#' @export
#' @examples
#' \dontrun{
#' get_datasets_from_a_catalog(
#' 'https://data.gov.in/catalog/fishing-harbours-fisheries-statistics-2014',
#' limit_pages = Inf)
#' }
#' @seealso search_for_datasets
get_datasets_from_a_catalog <- function(catalog_link, limit_pages = 5L) {
  
  this_catalog_result <- get_link(catalog_link)
  
  next_pages <- this_catalog_result %>% html_nodes(css = '.pager-item a') %>% html_attr('href')
  
  next_pages <- next_pages[seq_along(next_pages) < limit_pages]
  
  next_page_results <- lapply(next_pages, . %>% mk_link %>% get_link)
  
  data_set_nodes <- c(list(this_catalog_result), next_page_results) %>%
    lapply(. %>% html_nodes(css = '.views-row.ogpl-grid-list')) %>% 
    unlist(recursive = FALSE, use.names = FALSE)
  
  lapply(data_set_nodes, extract_info_from_single_data_set) %>% 
    do.call(args = ., what = rbind)
}

#' @title Search for data sets
#' @description This function scrapes the data.gov.in search results and returns all the information available for the datasets. As this function doesn't use API and just parses the web pages, there needs to delay between successive requests, and there should be limits to the number of pages that the function downloads from the web. For a particular search input, there may be multiple pages of search results. Each result page contains a list of catalogs. And each catalog contains multiple pages, with each page containing a list of data sets. There are default limits at each one of these stages. Make them 'Inf' if you need to get all the results or if you don't expect a large number of results.
#' @param search_terms Either one string with multiple words separated by space, or a character vector with all the search terms
#' @param limit_search_pages Number of pages of search results to request. Default is 5. Make it Inf to get all.
#' @param return_catalog_list Default is FALSE. If TRUE, the function return will not look for data sets, and will only return the list of catalogs found.
#' @param limit_catalogs Number of catalogs that the function should parse to get the data sets. Default is 5. Make it Inf to get all.
#' @param limit_catalog_pages Number of pages to parse through, for each catalog. Default is 5. Make it Inf to get all.
#' @importFrom magrittr %>%
#' @importFrom xml2 read_html
#' @importFrom rvest html_nodes html_text html_attr
#' @export
#' @examples
#' \dontrun{
#' # Basic Use:
#' search_for_datasets('train usage')
#' 
#' # Advanced Use, specifying additional parameters
#' search_for_datasets(search_terms = c('state', 'gdp'),
#'                     limit_search_pages = 1,
#'                     limit_catalogs = 3,
#'                     limit_catalog_pages = 2)
#' search_for_datasets(search_terms = c('state', 'gdp'),
#'                     limit_search_pages = 2,
#'                     return_catalog_list = TRUE)
#' }
#' @seealso get_datasets_from_a_catalog
search_for_datasets <- function(search_terms,
                                limit_search_pages = 5L,
                                return_catalog_list = FALSE,
                                limit_catalogs = 5L,
                                limit_catalog_pages = 5L) {
  
  #TODO: Escaping of search terms
  search_terms_collapsed <- search_terms %>%
    paste(collapse = ' ') %>%
    gsub(pattern = ' +', replacement = '+')
  
  search_url <- mk_link(paste0('/catalogs?query=',
                               search_terms_collapsed,
                               '&sort_by=search_api_relevance',
                               '&sort_order=DESC',
                               '&items_per_page=9'))
  
  first_search_result <- get_link(search_url)
  
  next_pages_links <- first_search_result %>%
    html_nodes(css = '.pager-item a') %>%
    html_attr('href')
  
  next_pages_links <- next_pages_links[seq_along(next_pages_links) < limit_search_pages]
  
  next_pages_results <- lapply(next_pages_links, . %>% mk_link %>% get_link)
  
  catalogs_from_all_search_pages <- c(list(first_search_result), next_pages_results) %>% 
    lapply(extract_catalogs_from_search_result) %>% 
    do.call(what = rbind, args = .)
  
  if (return_catalog_list) {
    catalogs_from_all_search_pages$link <- vapply(X = catalogs_from_all_search_pages$link,
                                                  FUN = mk_link,
                                                  FUN.VALUE = 'text',
                                                  USE.NAMES = FALSE)
    return(catalogs_from_all_search_pages) 
  }
  
  catalogs_from_all_search_pages <- catalogs_from_all_search_pages[seq_len(nrow(catalogs_from_all_search_pages)) < limit_catalogs, , drop = FALSE]
  
  ans <- lapply(X = catalogs_from_all_search_pages$link,
                FUN = . %>%
                  mk_link %>%
                  get_datasets_from_a_catalog(.,limit_pages = limit_catalog_pages)
  ) %>% 
    do.call(what = rbind, args = .)
  
  if (is.null(ans) || (nrow(ans) == 0)) {
    return(data.frame(
      name             = character(0),
      granularity      = character(0),
      file_size        = character(0),
      downloads        = numeric(0),
      res_id           = character(0),
      csv              = character(0),
      ods              = character(0),
      xls              = character(0),
      json             = character(0),
      xml              = character(0),
      jsonp            = character(0),
      stringsAsFactors = FALSE
    ))
  }
  
  ans
}
