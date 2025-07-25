#MCD64A1 v006

library(rgee)
library(piggyback)

#Below I've modified some existing code to mask any data that isn't land data with sufficient information available
#There are additional filters we can apply using the QA data if we like, but this seems like a good start


#' @param image a QA image
#' @param qa binary numeric (e.g. 111 or 01) corresponding the QA settings to use. Note that this assumes you're starting with bit zero and doesn't handle shifts
#' @return an image resulting from the bitwiseAnd.  This can be transformed into a binary mask using $eq() or similar rgee functions
getQABits_match <- function(image, qa) {

  # Convert binary (character) to integer
  qa <- sum(2^(which(rev(unlist(strsplit(as.character(qa), "")) == 1))-1))

  # Return a mask band image, giving the qa value.
  image$bitwiseAnd(qa)



}


#' @param img A MCD64A1 rgee image,
#' @note this function sets the mask to ignore any date without bits zero and one ==1 (i.e. it ignores data from water and bad data)
MCD64A1_clean <- function(img) {
  # Extract the NDVI band
  fire_values <- img$select("BurnDate")

  # Extract the quality band
  fire_qa <- img$select("QA")

  # Compare the QA scores for the first two bits to a value of 1,1
  quality <- getQABits_match(fire_qa, "11")

  # Create a mask.  Since we only want cells that match both criteria, the bitwise logical for this is 1,1 (yes,yes).
  #The bitwise logical 1,1 translates to an integer value of 3, so we'll mask to everything that equals 3
  quality <- quality$eq(3)

  # Limit our observations to only pixels that have values of 1,1 for the first bits, per the binary "quality" raster (1=good, 0 = bad).
  fire_values$updateMask(quality)

  #Map$addLayer(fire_values)
}


#' @description This function will download fire layers (derived from MODIS 16 day products), skipping any that have been downloaded already.
#' @author Brian Maitner
#' @param temp_directory The directory the fire layers should be saved to prior to releasing, defaults to "data/raw_data/fire_modis/"
#' @param tag tag to be used for the Github release
#' @param domain domain (sf polygon) used for masking
#' @param max_layers the maximum number of layers to download at once.  Set to NULL to ignore.  Default is 50
#' @param sleep_time Amount of time to wait between attempts.  Needed to keep github happy
#' @import rgee
get_release_fire_modis <- function(temp_directory = "data/temp/raw_data/fire_modis/",
                                   tag = "raw_fire_modis",
                                   domain,
                                   max_layers = 50,
                                   sleep_time = 1,
                                   json_token,
                                   verbose = TRUE) {

  #Garbage cleanup, just in case

    gc()

  #  #Ensure directory is empty if it exists

    if(dir.exists(temp_directory)){

      if(verbose){message("Deleting directory")}
      unlink(file.path(temp_directory), recursive = TRUE, force = TRUE)

    }

  # make a directory if one doesn't exist yet

    if(!dir.exists(temp_directory)){

      if(verbose){message("Creating directory")}
      dir.create(temp_directory, recursive = TRUE)

    }

  # get list releases

    if(verbose){message("Getting metadata for releases")}

    released_files  <- pb_list(repo = "AdamWilsonLab/emma_envdata")


  #Make sure there is a release by attempting to create one.  If it already exists, this will fail

      if(!tag %in% released_files$tag){

        if(verbose){message("Creating a new release")}

        tryCatch(expr =   pb_new_release(repo = "AdamWilsonLab/emma_envdata",
                                         tag =  tag),
                 error = function(e){message("Previous release found")})


      }



  # Initialize earth engine (for targets works better if called here)
    #ee_Initialize()

  # Load ee image collection
    if(verbose){message("Loading image collection")}
    modis_fire <- ee$ImageCollection("MODIS/061/MCD64A1")

  #Format the domain

    if(verbose){message("Formatting the domain")}
    domain <- sf_as_ee(x = domain)
    domain <- domain$geometry()


  # Clean data using QA

    if(verbose){message("Cleaning the data")}
    fire_clean <- modis_fire$map(MCD64A1_clean)

  #Get a list of files already released

    if(verbose){message("Renaming release tag object")}

      release_tag <- tag

    if(verbose){message("Filtering to list of previously processed files")}

      released_files <-
      released_files %>%
        filter(tag == release_tag)

    if(verbose){message("Making date column in file info")}

      released_files$date <- gsub(pattern = ".tif",
                                  replacement = "",
                                  x = released_files$file_name)

    if(verbose){message("Filtering out non-tifs")}

      released_files <-
        released_files %>%
        dplyr::filter(file_name != "") %>%
        dplyr::filter(file_name != "log.csv") %>%
        dplyr::filter(file_name != "extent_log.csv")


  # check to see if any images have been downloaded already

    if(verbose){message("Checking for previous downloads and setting date accordingly")}

      if(nrow(released_files) == 0){

        newest <- lubridate::as_date(-1) #if nothing is downloaded, start in 1970

      }else{

        newest <- max(lubridate::as_date(released_files$date)) #if there are images, start with the most recent

      }


  # Filter the data to exclude anything you've already downloaded (or older)

    if(verbose){message("Filtering by date")}

      fire_new_and_clean <- fire_clean$filterDate(start = paste(as.Date(newest+1),sep = ""),
                                                  opt_end = paste(format(Sys.time(), "%Y-%m-%d"),sep = "") )


  # Function to optionally limit the number of layers downloaded at once

  if(!is.null(max_layers)){

    if(verbose){message("Comparing number of layers to download with max_layers")}

    if(verbose){message("Getting info on cleaned fire data")}

      info <- fire_new_and_clean$getInfo()

    if(verbose){message("Preparing list to download")}

      to_download <- unlist(lapply(X = info$features,FUN = function(x){x$properties$`system:index`}))
      to_download <- gsub(pattern = "_",replacement = "-",x = to_download)

    if(length(to_download) > max_layers){

      if(verbose){message("Pruning download to the maximum number of layers")}

      fire_new_and_clean <- fire_new_and_clean$filterDate(start = to_download[1],
                                                          opt_end = to_download[max_layers+1])

    }


  }


  # Check if anything to download

    if(length(fire_new_and_clean$getInfo()$features) == 0 ){

      message("Releases are already up to date.")
      return(max(gsub(pattern = "_",replacement = "-",x = released_files$date))) #return the last date that had been done


    }

  # Download

    if(verbose){message("Downloading image collection")}

      #Download layers
      if(length(fire_new_and_clean$getInfo()$features) == 1 ){

        # assign name

        file_name <- fire_new_and_clean$getInfo()$features[[1]]$properties$`system:index`

        # convert to image

        fire_new_and_clean_image <- fire_new_and_clean %>%
          ee$ImageCollection$toList(count = 1, offset = 0) %>%
          ee$List$get(0) %>%
          ee$Image()

        # download single image

        tryCatch(expr =
                   ee_as_stars(image = fire_new_and_clean_image,
                               region = domain,
                               dsn = file.path(temp_directory,file_name),
                               formatOptions = c(cloudOptimized = true),
                               drive_cred_path = json_token
                   ),
                 error = function(e){message("Captured an error in rgee/earth engine processing of NDVI.")}
        )#trycatch

      }else{

        tryCatch(expr =
                   ee_imagecollection_to_local(ic = fire_new_and_clean,
                                               region = domain,
                                               dsn = temp_directory,
                                               formatOptions = c(cloudOptimized = true),
                                               drive_cred_path = json_token
                                               #,scale = 463.3127
                   ),
                 error = function(e){message("Captured an error in rgee/earth engine processing of NDVI.")}
        )

      }#else


    #Push files to release

    # Get a list of the local files

    if(verbose){message("Getting list of downloaded files")}

    local_files <- data.frame(local_filename = list.files(path = temp_directory,
                                                          recursive = TRUE,
                                                          full.names = TRUE))

    # end things if nothing was downloaded

      if(nrow(local_files) == 0){
        message("Nothing downloaded")
        return(max(gsub(pattern = "_",replacement = "-",x = released_files$date))) #return the last date that had been done
      }



  #Push files to release


      # loop through and release everything

      if(verbose){message("Pushing files to releases")}

      for( i in 1:nrow(local_files)){

        if(verbose){message("Uploading file ",i, " of ", nrow(local_files))}

        Sys.sleep(sleep_time) #We need to limit our rate in order to keep Github happy

        pb_upload(file = local_files$local_filename[i],
                  repo = "AdamWilsonLab/emma_envdata",
                  tag = tag)

      } # end i loop

  # Delete temp files

    if(verbose){message("Deleting temporary directory")}

    unlink(file.path(temp_directory), recursive = TRUE, force = TRUE)


  # End
    message("\nFinished download MODIS fire layers")

    local_files %>%
      filter(grepl(pattern = ".tif$",x = local_filename)) %>%
      mutate(date_format = basename(local_filename)) %>%
      mutate(date_format = gsub(pattern = ".tif",replacement = "",x = date_format)) %>%
      mutate(date_format = gsub(pattern = "_",replacement = "-",x = date_format)) %>%
      mutate(date_format = lubridate::as_date(date_format))%>%
      dplyr::select(date_format) -> local_files

      return(as.character(max(local_files$date_format))) # return the date of the latest file that was updated


} #end fx


