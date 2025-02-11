### 5-refine_occurrence_data.R
### Authors: Emily Beckman Bruns & Shannon M Still
### Supporting institutions: The Morton Arboretum, Botanic Gardens Conservation 
#   International-US, United States Botanic Garden, San Diego Botanic Garden,
#   Missouri Botanical Garden, UC Davis Arboretum & Botanic Garden
### Funding: Base script funded by the Institute of Museum and Library 
#   Services (IMLS MFA program grant MA-30-18-0273-18 to The Morton Arboretum).
#   Moderate edits were added with funding from a cooperative agreement
#   between the United States Botanic Garden and San Diego Botanic Garden
#   (subcontracted to The Morton Arboretum), and NSF ABI grant #1759759
### Last Updated: June 2023 ; first written Feb 2020
### R version 4.3.0

### DESCRIPTION:
  ## This script flags potentially suspect points by adding a column for each 
  #   type of flag, where FALSE = flagged. 
  ## Much of the flagging is done through or inspired by the
  #   CoordinateCleaner package, which was created for "geographic cleaning
  #   of coordinates from biologic collections...Cleaning geographic coordinates
  #   by multiple empirical tests to flag potentially erroneous coordinates, 
  #   addressing issues common in biological collection databases."
  #   See the article here:
  #   https://besjournals.onlinelibrary.wiley.com/doi/full/10.1111/2041-210X.13152

### INPUTS:
  ## target_taxa_with_synonyms.csv
  #   List of target taxa and synonyms; see example in the "Target taxa list"
  #   tab in Gap-analysis-workflow_metadata workbook; Required columns include: 
  #   taxon_name, taxon_name_accepted, and taxon_name_status (Accepted/Synonym).
  ## Occurrence data compiled in 4-compile_occurrence_data.R
  ## polygons ...

### OUTPUTS:
  ## "taxon_points_ready-to-vet" folder 
  #   For each taxon in your target taxa list, a CSV of occurrence records with 
  #   newly-added flagging columns (e.g., Asimina_triloba.csv)
  ## occurrence_record_summary_YYYY_MM_DD.csv
  #   Add to the summary table created in 4-compile_occurrence_data.R: number of
  #   flagged records in each flag column

################################################################################
# Load libraries
################################################################################

my.packages <- c('tidyverse','textclean','CoordinateCleaner','tools','terra')
  # versions I used (in the order listed above): 2.0.0, 0.9.3, 2.0-20, 4.3.0, 1.7-29
#install.packages (my.packages) #Turn on to install current versions
lapply(my.packages, require, character.only=TRUE)
rm(my.packages)

################################################################################
# Set working directory
################################################################################

# use 0-set_working_directory.R script:
source("/Users/emily/Documents/GitHub/conservation-gap-analysis/spatial-analysis-workflow/0-set_working_directory.R")

# create folder for output data
data_out <- "taxon_points_ready-to-vet"
if(!dir.exists(file.path(main_dir,occ_dir,standardized_occ,data_out)))
  dir.create(file.path(main_dir,occ_dir,standardized_occ,data_out), 
             recursive=T)

# assign folder where you have input data (saved in 4-compile_occurrence_data.R)
data_in <- "taxon_points_raw"

################################################################################
# Read in data
################################################################################

# read in target taxa list
taxon_list <- read.csv(file.path(main_dir, taxa_dir,"target_taxa_with_synonyms.csv"),
                       header=T, colClasses="character",na.strings=c("","NA"))

# read in world countries layer created in 1-prep_gis_layers.R
world_polygons <- vect(file.path(main_dir,gis_dir,"world_countries_10m",
                             "world_countries_10m.shp"))

# read in urban areas layer created in 1-prep_gis_layers.R
urban_areas <- vect(file.path(main_dir,gis_dir,"urban_areas_50m",
                              "urban_areas_50m.shp"))

################################################################################
# Iterate through taxon files and flag potentially suspect points
################################################################################

# list of taxon files to iterate through
taxon_files <- list.files(path=file.path(main_dir,occ_dir,standardized_occ,data_in), 
                          ignore.case=FALSE, full.names=FALSE, recursive=TRUE)
target_taxa <- file_path_sans_ext(taxon_files)

# start a table to add summary of results for each species
summary_tbl <- data.frame(
  taxon_name_accepted = "start", 
  total_pts = "start",
  unflagged_pts = "start", 
  selected_pts = "start", 
  .cen = "start", 
  .urb = "start",
  .inst = "start",
  .con = "start", 
  .outl = "start", 
  .nativectry = "start", 
  .yr1950 = "start", 
  .yr1980 = "start",
  .yrna = "start", 
    stringsAsFactors=F)

# select columns and order
  col_names <- c( 
    #data source and unique ID
    "UID","database","all_source_databases",
    #taxon
    "taxon_name_accepted","taxon_name_status",
    "taxon_name","scientificName","genus","specificEpithet",
    "taxonRank","infraspecificEpithet","taxonIdentificationNotes",
    #event
    "year","basisOfRecord",
    #record-level
    "nativeDatabaseID","institutionCode","datasetName","publisher",
    "rightsHolder","license","references","informationWithheld",
    "issue","recordedBy",
    #occurrence
    "establishmentMeans","individualCount",
    #location
    "decimalLatitude","decimalLongitude",
    "coordinateUncertaintyInMeters","geolocationNotes",
    "localityDescription","locality","verbatimLocality",
    "locationNotes","municipality","higherGeography","county",
    "stateProvince","country","countryCode","countryCode_standard",
    "latlong_countryCode",
    #additional optional data from target taxa list
    "rl_category","ns_rank",
    #flag columns
    ".cen",".urb",".inst",".con",".outl",
    ".nativectry",
    ".yr1950",".yr1980",".yrna"
  )

## iterate through each species file to flag suspect points
cat("Starting ","target ","taxa (", length(target_taxa)," total)",".\n\n",sep="")

for (i in 1:length(target_taxa)){

  taxon_file <- target_taxa[i]
  taxon_nm <- gsub("_", " ", taxon_file)
  taxon_nm <- mgsub(taxon_nm, c(" var "," subsp "), c(" var. "," subsp. "))

  # bring in records
  taxon_now <- read.csv(file.path(main_dir,occ_dir,standardized_occ,data_in,
    paste0(taxon_file, ".csv")))
  
  
  # now we will go through a set of tests to flag potentially suspect records...

  
  ### CHECK LAT-LONG COUNTRY AGAINST "ACCEPTED" NATIVE COUNTRY DISTRUBUTION; 
  #   flag when the lat-long country is not in the list of native countries;
  #   we use the native countries compiled in 1-get_taxa_metadata.R, which
  #   combines the IUCN Red List, BGCI GlobalTreeSearch, and manually-added data
  native_ctrys <- unique(unlist(strsplit(taxon_now$all_native_dist_iso2, "; ")))
  if(!is.na(native_ctrys[1])){
  # flag records where native country doesn't match record's coordinate location
    taxon_now <- taxon_now %>% 
      mutate(.nativectry=(ifelse(latlong_countryCode %in% native_ctrys, 
                                 TRUE, FALSE)))
  } else {
    taxon_now$.nativectry <- NA
  }

  
  ### COMPARE THE COUNTRY LISTED IN THE RECORD VS. THE LAT-LONG COUNTRY; flag
  #   when there is a mismatch; CoordinateCleaner package has something like 
  #   this but also flags when the record doesn't have a country..didn't love that
  taxon_now <- taxon_now %>% mutate(.con=(ifelse(
    (as.character(latlong_countryCode) == as.character(countryCode_standard) &
       !is.na(latlong_countryCode) & !is.na(countryCode_standard)) |
      is.na(latlong_countryCode) | is.na(countryCode_standard), TRUE, FALSE)))
  
  
  ### FLAG OLDER RECORDS, based on two different year cutoffs (1950 & 1980)
  taxon_now <- taxon_now %>% mutate(.yr1950=(ifelse(
    (as.numeric(year)>1950 | is.na(year)), TRUE, FALSE)))
  taxon_now <- taxon_now %>% mutate(.yr1980=(ifelse(
    (as.numeric(year)>1980 | is.na(year)), TRUE, FALSE)))
  
  
  ### FLAG RECORDS THAT DON'T HAVE A YEAR PROVIDED
  taxon_now <- taxon_now %>% mutate(.yrna=(ifelse(
    !is.na(year), TRUE, FALSE)))
  
  
  ### FLAG RECORDS THAT HAVE COORDINATES NEAR BIODIVERSITY INSTITUTIONS AND/OR
  ###   COUNTRY AND STATE/PROVINCE CENTROIDS
  taxon_now <- CoordinateCleaner::clean_coordinates(taxon_now,
    lon = "decimalLongitude", lat = "decimalLatitude",
    species = "taxon_name_accepted",
    # radius around country/state centroids (meters); default=1000
    centroids_rad = 500, 
    # radius around biodiversity institutions (meters)
    inst_rad = 100, 
    tests = c("centroids","institutions"))
  
  
  ## FLAG RECORDS THAT HAVE COORDINATES IN URBAN AREAS
  if(nrow(taxon_now)<2){
    taxon_now$.urb <- NA
    print("Taxa with fewer than 2 records will not be tested.")
  } else {
    taxon_now <- as.data.frame(taxon_now)
    flag_urb <- CoordinateCleaner::cc_urb(taxon_now,
      lon = "decimalLongitude",lat = "decimalLatitude",
      ref = urban_areas, value = "flagged")
    taxon_now$.urb <- flag_urb
  }
  
  
  ### FLAG SPATIAL OUTLIERS
  taxon_now <- as.data.frame(taxon_now)
  flag_outl <- CoordinateCleaner::cc_outl(taxon_now,
    lon = "decimalLongitude",lat = "decimalLatitude",
    species = "taxon_name_accepted", 
    # read more about options for the method and the multiplier:
    #   https://www.rdocumentation.org/packages/CoordinateCleaner/versions/2.0-20/topics/cc_outl
    method = "quantile", mltpl = 4, 
    value = "flagged")
  taxon_now$.outl <- flag_outl

  
  # set everything up for saving...

  # set column order and remove a few unnecessary columns
  taxon_now <- taxon_now %>% dplyr::select(all_of(col_names))
  
  # subset of completely unflagged points
  total_unflagged <- taxon_now %>%
    filter(.cen & .urb & .inst & .con & .outl & .yr1950 & .yr1980 & .yrna &
             (.nativectry | is.na(.nativectry)) &
             basisOfRecord != "FOSSIL_SPECIMEN" & 
             basisOfRecord != "LIVING_SPECIMEN" &
             establishmentMeans != "INTRODUCED" & 
             establishmentMeans != "MANAGED" &
             establishmentMeans != "CULTIVATED"
    )
  
  # OPTIONAL subset of unflagged points based on selected filters you'd like 
  #   to use; change as desired; commented out lines are those we aren't using
  select_unflagged <- taxon_now %>%
    filter(.cen & .inst & .outl & 
             #.urb & .con & .yr1950 & .yr1980 & .yrna &
             (.nativectry | is.na(.nativectry)) &
             basisOfRecord != "FOSSIL_SPECIMEN" & 
             basisOfRecord != "LIVING_SPECIMEN" &
             establishmentMeans != "INTRODUCED" & 
             establishmentMeans != "MANAGED" &
             establishmentMeans != "CULTIVATED"
    )
  
  # add data to summary table
  summary_add <- data.frame(
    taxon_name_accepted = taxon_nm,
    #total_pts = nrow(taxon_now),
    unflagged_pts = nrow(total_unflagged),
    selected_pts = nrow(select_unflagged),
    .cen = sum(!taxon_now$.cen),
    .urb = sum(!taxon_now$.urb),
    .inst = sum(!taxon_now$.inst),
    .con = sum(!taxon_now$.con),
    .outl = sum(!taxon_now$.outl),
    .nativectry = sum(!taxon_now$.nativectry),
    .yr1950 = sum(!taxon_now$.yr1950),
    .yr1980 = sum(!taxon_now$.yr1980),
    .yrna = sum(!taxon_now$.yrna),
    stringsAsFactors=F)
  summary_tbl[i,] <- summary_add

  # WRITE NEW FILE
  write.csv(taxon_now, file.path(main_dir,occ_dir,standardized_occ,data_out,
    paste0(taxon_file, ".csv")), row.names=FALSE)

  cat("Ending ", taxon_nm, ", ", i, " of ", length(target_taxa), ".\n\n", sep="")
}

# add summary of points to summary we created in 4-compile_occurrence_data.R
file_nm <- list.files(path = file.path(main_dir,occ_dir,standardized_occ),
                      pattern = "summary_of_occurrences", full.names = T)
orig_summary <- read.csv(file_nm)
summary_tbl2 <- full_join(orig_summary,summary_tbl)

# write summary table
write.csv(summary_tbl2, file.path(main_dir,occ_dir,standardized_occ,
  paste0("summary_of_occurrences_", Sys.Date(), ".csv")),row.names = F)
