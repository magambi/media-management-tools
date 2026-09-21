<# 
.SYNOPSIS
	Get the list of New York Times bestsellers.
.DESCRIPTION
	Gets the list of New York Times bestsellers (aka best sellers).
    All bestseller lists are read unless the -ListName is specified.
    The current bestseller list is read unless the -StartDate or -EndDate is specified.
    Note that the NYT API restricts requests to 5 per minute and 500 per day.
    If a date range is specified, then a 15 second delay will be added between requests.

    Books in the bestseller list(s) are saved to a comma-separated-values (CSV) file.
    The book title (TITLE) and author (AUTHOR) is saved.
 
    A 'NYT Bestseller' tag (TAGS) is saved to the CSV file for the book.
    Addtionally, the name of bestseller list, e.g. NYT Hardcover Fiction, is added.
    If the list name contains 'Fiction' or 'Nonfiction', that tag is also added.
    Several command line parameters affect the tags that are saved.
    Multiple tags are separated by '|' (vertical bar).

    The CSV output file is intended to be used by other scripts or tools
    to import tags to book libraries.  For example, update-abs-book-tags.ps1.

    Linux: To execute on Linux, invoke as:
        pwsh scriptname.ps1 [-help or other parameters]
#>
[CmdletBinding()]
param (
    # The CSV output file containing book titles and tags.  
    # The first line of the CSV file contains the column headers.
    # Multiple tags in the TAGS column are separated by '|' (a vertical bar).
    # Default is 'nyt_bestsellers.csv'
    [string]$BookTagsPath = "nyt_bestsellers.csv",


    # The name of the NYT bestseller list if only a single list is desired, e.g. Hardcover Nonfiction.
    # If blank, all NYT bestseller lists are read.
    [string] $NytListName,

    # The start date for the NYT bestseller. If specified, all weekly bestseller lists
    # from the start date are added to the CSV output file.
    # The default is the current date.
    [datetime]$StartDate = $(Get-Date).Date,

    # The end date for the NYT bestseller. If specified, all weekly bestseller lists
    # up to the end date are added to the CSV output file.
    [datetime]$EndDate = $(Get-Date).Date,

    # If -BestsellerTagOnly is specified, only 'NYT Bestseller' tag is added.
    # The full list name tag, e.g. 'NYT Hardcover Nonfiction' is not added.
    [switch]$BestsellerTagOnly,

    # If -NoFictionTag is specified, the 'Fiction' and 'Nonfiction' tags are not added.
    [switch]$NoFictionTag,

    # The configuration file containing peristent configuration values.
    # Configuration values must be set the personal NYT API key.
    # The configuration file can contain persistent values for the parameters above.
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "config.psd1"),

    # Show help for -help parameter.
	[switch] $Help
)

# Set strict error handlingget
$ErrorActionPreference = "Stop"

# HELP: The <# .SYNOPSIS #> and param sections above must be first wihout additional comments.
# They are used with the -help parameter.  Parameter comments are displayed in the help.
if ($Help) {
	Get-Help $PSCommandPath -detailed
	exit 0
}
# If called from command line, show help reminder. 
elseif ([string]::IsNullOrEmpty($MyInvocation.ScriptName)) {
	Write-Output "For help, run: $PSCommandPath -help"
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
Test-ValidConfigValue -ConfigName "NytApiKey"

#----------------------------------------------------------------------
# Collection to store book entries before exporting
$bookList = [System.Collections.Generic.List[PSObject]]::new()
$apiRequested = $false

for ($publishedDate = $StartDate;
    $publishedDate -lt $($EndDate.AddDays(7));
    $publishedDate = $publishedDate.AddDays(7)) {
 
    # Wait 15 seconds if NYT API was called recently.
    if ($apiRequested) {
        Write-Output "Waiting 15 seconds before next NYT API request..."
        Start-Sleep -Seconds 15
    } 
 
    # Fetch current overview endpoint which contains all lists and their current books
    $dateString = $publishedDate.ToString("yyyy-MM-dd")
    Write-Output "Fetching NYT Bestsellers for $dateString"
    $overviewUrl = "https://api.nytimes.com/svc/books/v3/lists/overview.json?api-key=$NytApiKey&published_date=$dateString"

    try {
        $overviewResponse = Invoke-RestMethod -Uri $overviewUrl -Method Get
        $apiRequested = $True
    } catch {
        Write-Error "Failed to retrieve overview from NYT API. Verify your API key and network connection."
        Write-Error "Error Details: $_"
        exit 1
    }

    # Iterate through each list contained in the overview response
    foreach ($list in $overviewResponse.results.lists) {
        $displayName = $list.display_name

        # Determine Fiction vs. Nonfiction classification from list display name
        if ($displayName -match 'Fiction' -and $displayName -notmatch 'Nonfiction') {
            $fictionTag = "Fiction"
        } elseif ($displayName -match 'Nonfiction') {
            $fictionTag = "Nonfiction"
        } else {
            $fictionTag = $null
        }

        $listTag = "NYT $displayName"

        # Extract books attached directly to this list
        foreach ($book in $list.books) {
            $tags = [System.Collections.Generic.List[string]]::new()
            $tags.Add("NYT Bestseller")

            if (-not $BestsellerTagOnly ) {
                $tags.Add($listTag)
            }

            if ($fictionTag -and -not $NoFictionTag) {
                $tags.Add($fictionTag)
            }

            # Join tags with pipe delimiter to match the CSV input format for Audiobookshelf
            $tagString = $tags -join "|"

            # Add structured book object to collection
            # TODO Instead of multiple rows for a book, add the tags to existing rows.
            $bookList.Add([PSCustomObject]@{
                Title  = $book.title
                Author = $book.author
                Tags   = $tagString
            })
        }
    }

}

# Export collected records to CSV file using UTF-8 encoding
$bookList | Export-Csv -Path $BookTagsPath -NoTypeInformation -Encoding utf8

Write-Output "Done! Exported $($bookList.Count) books to: $BookTagsPath"
