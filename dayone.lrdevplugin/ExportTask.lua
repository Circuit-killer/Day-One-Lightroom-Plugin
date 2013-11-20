-- Copyright (c) 2013, Philip Lundrigan
-- All rights reserved.
-- BSD License

local random = math.random
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrDialogs = import 'LrDialogs'
local LrDate = import 'LrDate'
local LrStringUtils = import 'LrStringUtils'
local LrXml = import 'LrXml'

local function uuid()
    local template ='xxxxxxxxxxxx4xxxyxxxxxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
        return LrStringUtils.upper(string.format('%x', v))
    end)
end

local function split( str, delimiter )
    local result = { }
    local from  = 1
    local delim_from, delim_to = string.find( str, delimiter, from  )
    while delim_from do
        table.insert( result, LrStringUtils.trimWhitespace( string.sub( str, from , delim_from-1 ) ) )
        from  = delim_to + 1
        delim_from, delim_to = string.find( str, delimiter, from  )
    end
    table.insert( result, LrStringUtils.trimWhitespace( string.sub( str, from  ) ) )
    return result
end

local function validJournalPath( path )
    if not LrFileUtils.exists( path ) then
        return false, "Journal directory does not exist."
    elseif not LrFileUtils.exists( LrPathUtils.child(path, 'entries') ) then
        -- This directory should really be in here, if it is a valid journal
        -- Let's just error out and make the user pick a different directory
        return false, "\"entries\" directory does not exist."
    elseif not LrFileUtils.exists( LrPathUtils.child(path, 'photos') ) then
        -- When the user has not added a photo yet, the "photos" directory does not exist
        -- Let's just create it for them.
        LrFileUtils.createDirectory( LrPathUtils.child(path, 'photos') )
    end

    return true, ""
end

local function getUniqueUUID( path )
    local fileName = uuid()

    while LrFileUtils.exists( LrPathUtils.child( path, fileName )) do
        fileName = uuid()
    end

    return fileName
end

local function getLocation( gps )
    local LrHttp = import "LrHttp"

    local lat = gps.latitude
    local long = gps.longitude

    local url = "http://maps.googleapis.com/maps/api/geocode/xml?latlng=" .. lat .. "," .. long .. "&sensor=true"
    local xml = LrHttp.get( url )

    root = LrXml.parseXml( xml )
    status = root:childAtIndex( 1 ):text()

    local xsltString = [[<?xml version="1.0" encoding="UTF-8"?>
    <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
        <xsl:output method="text"/>
        <xsl:template match="GeocodeResponse">
            <xsl:apply-templates select="result"/>
        </xsl:template>
        <xsl:template match="result">
            <xsl:apply-templates select="address_component"/>
        </xsl:template>
        <xsl:template match="address_component">
            <xsl:value-of select="long_name" />,
        </xsl:template>
    </xsl:stylesheet>
    ]]

    local location = split( root:transform( xsltString ), ',' )

    local results = {}
    results.placeName = location[1]
    results.locality = location[2]
    results.adminArea = location[4]
    results.country = location[5]
    results.latitude = lat
    results.longitude = long

    return results
end

local function formatTime( time )
    tz, ds = LrDate.timeZone()
    if ds then
        time = time - tz - 3600
    else
        time = time - tz
    end

    return LrDate.timeToUserFormat( time, "%Y-%m-%dT%H:%M:%SZ" )
end

local function generateEntry(date, starred, location, tags, uuid, activity)

    local entryString = [[
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>%s
    <key>Creation Date</key>
    <date>%s</date>
    <key>Entry Text</key>
    <string></string>%s
    <key>Starred</key>
    <%s/>%s
    <key>UUID</key>
    <string>%s</string>
</dict>
</plist>
    ]]

    -- take care of activity if necessary
    local activityString = ''
    if activity ~= nil then
        activityString = [[

    <key>Activity</key>
    <string>%s</string>]]

        activityString = string.format( activityString, activity)
    end

    -- take care of location if necessary
    local locationString = ''
    if location ~= nil then
        locationString = [[

    <key>Location</key>
    <dict>
        <key>Administrative Area</key>
        <string>%s</string>
        <key>Country</key>
        <string>%s</string>
        <key>Latitude</key>
        <real>%s</real>
        <key>Locality</key>
        <string>%s</string>
        <key>Longitude</key>
        <real>%s</real>
        <key>Place Name</key>
        <string>%s</string>
    </dict>]]

        locationString = string.format( locationString,
                                        location.adminArea,
                                        location.country,
                                        location.latitude,
                                        location.locality,
                                        location.longitude,
                                        location.placeName )
    end

    -- take care of tags if necessary
    tag = ''
    if next(tags) ~= nil  then
        tag = tag .. '\n\t<array>'

        for key,value in pairs(tags) do
            tag = tag .. '\n\t\t<string>' .. key .. '</string>'
        end

        tag = tag .. '\n\t</array>'
    else
        tag = '\n\t<array/>'
    end

    tagString = [[

    <key>Tags</key>%s]]

    tagString = string.format( tagString, tag )

    entryString = string.format( entryString,
                                 activityString,
                                 formatTime( date ),
                                 locationString,
                                 starred,
                                 tagString,
                                 uuid )

    return entryString
end

local function createEntry( exportParams, photo, uuid )
    local date = exportParams.use_time and
                 photo:getRawMetadata("dateTimeOriginal") or
                 LrDate.currentTime()

    -- get the correct path
    local entries = LrPathUtils.child( exportParams.path, 'entries' )
    local path = LrPathUtils.child( LrPathUtils.standardizePath( entries ), uuid .. '.doentry' )

    -- get the keywords
    local oldKeywords = exportParams.use_keywords and
                        split( photo:getFormattedMetadata("keywordTags"), ',' ) or
                        {}

    local newKeywords = exportParams.use_specific_tags and
                        split( exportParams.tags, ',' ) or
                        {}

    local activity = exportParams.use_activity and
                     exportParams.activity or
                     nil

    -- join two lists together
    local tags = {}
    for _, l in ipairs(oldKeywords) do
        if l ~= "" then
            tags[l] = true
        end
    end

    for _, l in ipairs(newKeywords) do
        if l ~= "" then
            tags[l] = true
        end
    end

    -- get location
    local location = nil
    if exportParams.use_location and photo:getRawMetadata("gps") then
        location = getLocation( photo:getRawMetadata("gps") )
    end

    -- write entry
    local f = io.open( path, "w" )
    f:write( generateEntry( date, exportParams.star, location, tags, uuid, activity ))
    f:close()

end

local function createPhoto( exportParams, photoPath, uuid )
    local photos = LrPathUtils.child( exportParams.path, 'photos' )
    LrFileUtils.copy( photoPath, LrPathUtils.child(LrPathUtils.standardizePath(photos), uuid .. '.jpg') )
end



ExportTask = {}

function ExportTask.processRenderedPhotos( functionContext, exportContext )

    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable

    local nPhotos = exportSession:countRenditions()
    local progressScope = exportContext:configureProgress {
                            title = nPhotos > 1 and
                                    "Adding " .. nPhotos .. " photos to Day One" or
                                    "Adding one photo to Day One",
    }

    -- Check if selected journal location exists
    valid, errorMessage = validJournalPath( exportParams.path )
    if not valid then
        LrDialogs.showError( "Something is wrong with the journal location \n(" .. exportParams.path .. ")\n you selected. " .. errorMessage)
        return
    end

     -- Iterate through photo renditions.
    for _, rendition in exportContext:renditions{ stopIfCanceled = true } do

        -- Wait for next photo to render.
        local success, pathOrMessage = rendition:waitForRender()

        if progressScope:isCanceled() then break end

        if success then
            local uuid = getUniqueUUID( exportParams.path )

            createEntry( exportParams, rendition.photo, uuid )
            createPhoto( exportParams, pathOrMessage, uuid )

            -- clean up
            LrFileUtils.delete( pathOrMessage )

        else
            LrDialogs.message( pathOrMessage )
        end

    end
end
