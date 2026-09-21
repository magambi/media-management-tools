<# 
.SYNOPSIS
	Add tags to Audiobookshelf books from CSV file of titles and tags.
.DESCRIPTION
	Reads a comma-separate-values (CSV) files containing book titles and tags.
    Search the Audiobookshelf library for a matching book title.
    Adds any of the tags that do not exist for the book.

    Linux: To execute on Linux, invoke as:
        pwsh scriptname.ps1 [-help or other parameters]
#>
[CmdletBinding()]
param (
    # The CSV file containing book titles and tags.  
    # The first line of the CSV file must contain the column headers.
    # The columns 'TITLE' and 'TAGS' must exist. Header names are case-insensitive.
    # Other columns can exist, but are ignored.
    # Multiple tags in the TAGS column are separated by '|' (a vertical bar).
    [string]$BookTagsPath,

    # The configuration file containing peristent configuration values.
    # Configuration values must be set to local Audiobookshelf server.
    # The configuration file can contain persistent values for the parameters above.
    [string]$ConfigPath = ".\config.psd1",

    # Show help for -help parameter.
	[switch] $Help
)

# Set strict error handling
$ErrorActionPreference = "Stop"

# HELP: The <# .SYNOPSIS #> and param sections above must be first wihout additional comments.
# They are used with the -help parameter.  Parameter comments are displayed in the help.
if ($Help) {
	Get-Help $PSCommandPath -detailed
	exit 0
}
# If called from command line, show help reminder. 
elseif ([string]::IsNullOrEmpty($MyInvocation.ScriptName)) {
	Write-Host "For help, run: $PSCommandPath -help"
}

if (-not (Test-Path -Path $BookTagsPath)) {
    Write-Error "Book Tags CSV file '$BookTagsPath' not found."
    exit 1
}

# Include the configuration parameters.
if (Test-Path -Path $ConfigPath) {
    $config = Import-PowerShellDataFile -Path $ConfigPath
    # Dynamically create local variables matching the config keys
    foreach ($entry in $config.GetEnumerator()) {
        Set-Variable -Name $entry.Key -Value $entry.Value
    }
 }
function Test-ValidConfigValue {
    param (
        [string]$ConfigName
    )

    $value = Get-Variable -Name $ConfigName -ValueOnly -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $value.StartsWith("a1b2c3d4")) {
        Write-Error "Configuration value '$ConfigName' is invalid or blank. Set value in $ConfigPath"
        exit 1
    }
    return
}
Test-ValidConfigValue -ConfigName "AbsUrl"
Test-ValidConfigValue -ConfigName "AbsLibraryId"
Test-ValidConfigValue -ConfigName "AbsApiToken"

#----------------------------------------------------------------------
# Import CSV data
$csvData = Import-Csv -Path $BookTagsPath

# Set up API authorization headers
$headers = @{
    "Authorization" = "Bearer $AbsApiToken"
    "Content-Type"  = "Application/json"
}

foreach ($row in $csvData) {
    # Trim inputs and normalize empty strings
    $title = $row.Title.Trim()
    #$author = $row.Author.Trim()
    $tagsString = $row.Tags

    if ([string]::IsNullOrWhiteSpace($title)) { continue }

    # Parse target tags from pipe-separated string
    $targetTags = if (-not [string]::IsNullOrWhiteSpace($tagsString)) {
        $tagsString -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    } else {
        @()
    }

    # Search ABS for item matching title and author
    # Note: Searching by title and author does not work.
    $searchQuery = "$title"
    $encodedQuery = [System.Web.HttpUtility]::UrlEncode($searchQuery)
    $searchUrl = "$AbsUrl/api/libraries/$AbsLibraryId/search?q=$encodedQuery"

    try {
        $searchResponse = Invoke-RestMethod -Uri $searchUrl -Method Get -Headers $headers
    } catch {
        Write-Error "Failed to connect to Audiobookshelf API for '$title'."
        Write-Error "Error Details: $_"
        exit 1
    }

    # If no books found, continue.
    if ($searchResponse.book.count -eq 0) {
        "{0,-50} - Book not in library" -f $title
        continue
    }

    # ABS does not search for exact titles. Loop through resuts to find exact match (case-insensitive)
    $item = $null
    foreach ($book in $searchResponse.book) {
        $itemTitle = $book.libraryItem.media.metadata.title
        # $itemAuthor = $book.libraryItem.media.metadata.author[0].name
        # if ($itemTitle -eq $title -and $itemAuthor -eq $author) {
        if ($itemTitle -eq $title) {
            $item = $book.libraryItem
            break
        }
    }

    if (-not $item) {
        "{0,-50} - Book not in library" -f $title
        continue
    }

    $itemId = $item.id
    
    # Retrieve existing tags from metadata (defaulting to empty array if null)
    $existingTags = @()
    if ($item.media.tags) {
        $existingTags = @($item.media.tags)
    }

    # Determine tags that need to be added
    $tagsToAdd = $targetTags | Where-Object { $_ -notin $existingTags }

    # If there are new tags, merge and update metadata in ABS
    if ($tagsToAdd.Count -gt 0) {
        $updatedTags = @($existingTags + $tagsToAdd | Select-Object -Unique)

        $payload = @{
            tags = $updatedTags
        } | ConvertTo-Json -Depth 3

        $updateUrl = "$AbsUrl/api/items/$itemId/media"
        
        $updatedItem = $null
        try {
            $updatedItem = Invoke-RestMethod -Uri $updateUrl -Method Patch -Headers $headers -Body $payload
            $addedString = $tagsToAdd -join ", "
            "{0,-50} - Tags added: {1}" -f $title, $addedString
        } catch {
            Write-Error "Error updating book tags for $title"
            Write-Error "Error Details: $_"
            exit 1
        }
    } else {
        "{0,-50} - No tags added" -f $title
    }
} # end of foreach ($row in $csvData)

Write-output "Completed processing book tags file '$BookTagsPath'."
