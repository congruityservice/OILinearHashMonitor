Set-StrictMode -Version 2.0

#Name of the file to output raw stats
$statExportFile = "lhstats.csv"

#Store the output stats in the current script directory
$Invocation = (Get-Variable MyInvocation).Value
$statsExportFilePath = Join-Path (Split-Path $Invocation.MyCommand.Path) $statExportFile

Write-Host "Use CTRL+C to end."
Write-Host "Logging results to:" $statsExportFilePath

#By default show the stat headers at least once.
$displayHeader = $true

#Track number of stats reported
$iterations = 0

$displayRealtimeStats = $false

if($displayRealtimeStats -eq $false) {
    write-host "Generating stats for first 1 minute period. Please wait..."
}

#Periodically re-show the column headers at this interval.
#Set to 0 to disable.
$displayHeaderInterval = 0

#Define storage and size of running average variables.
$stats5min = New-Object System.Collections.ArrayList
$sizeMax5min = (5 * 60)
$stats1min = New-Object System.Collections.ArrayList
$sizeMax1min = (1 * 60)

#Placeholder global variable to store the process name.
#Set later via function call to lookup value.
$ProcessName_LinearHash = ""

#Counters to query when checking the LinearHash service
$counters = @(
"% Processor Time",
"IO Read Operations/sec",
"IO Write Operations/sec",
"IO Other Operations/sec",
"IO Read Bytes/sec",
"IO Write Bytes/sec",
"IO Other Bytes/sec")

Function resolveLinearHashEXE() {
    
    #Query the list of services for the LinearHash service EXE path
    $pathLinearHash = Get-WmiObject win32_service | ?{$_.Name -eq 'LinearHash'} | Select-Object -Expand PathName
    if ([String]::IsNullOrEmpty($pathLinearHash) -eq $True) {
        #Return nothing if not found
        return ""
    }

    #Chop starting after the last slash
    $posChopStart = $pathLinearHash.LastIndexOf('\') + 1

    #Chop enough up to the last period file extension
    $posChopLen = $pathLinearHash.LastIndexOf('.') - $posChopStart

    #Extract the EXE name excluding the file extension
    $lhEXE = $pathLinearHash.Substring($posChopStart,$posChopLen)

    return $lhEXE
}

Function calculateAverages($stats, $desc) {

    #Visual length of the description column in characters
    $descColLen = 27

    #Container object of columns containing the average values for each column    
    $tmpAvgCol = New-Object PSObject

    #Setup the description column
    $i = $desc.PadRight($descColLen, " ") + "";
    #$x = "        Averages           "
    $x = "Averages                   "
    $tmpAvgCol | Add-Member -Type NoteProperty -Name $i -Value $x
    
    #For each of the counters calculate the average
    foreach($i in $Global:counters){
    
        #Manipulate the column headers
        $i_after = $i -replace "Bytes/sec","b/s"
        if ($i -ne $i_after) {
            $scaleChange = $true
        } else {
            $scaleChange = $false
        }
        $i = $i_after
        $i = $i -replace "Operations/sec","op/s"
        $i = $i -replace "IO ",""
        $i = $i -replace "% Processor Time","CPU %"

        #Measure the average
        $x = $stats | measure-object $i -Average | Select-Object -expand Average
    
        #Write-Host "Avg: " $i " Val: " $x

        if ($scaleChange -eq $true) {
            $x = $x / 1024
            $i = $i -replace "b/s","K/s"
        } 

        $x = [math]::Round($x)
        $x = "{0:N0}" -f $x


        #Add this column to the container object
        $tmpAvgCol | Add-Member -Type NoteProperty -Name $i -Value $x
    
    } #foreach($i in $Global:counters){

    return ,$tmpAvgCol
}

function trim-StatCollection($col, $timePeriodSec) {
    $timeProperty = "Timestamp"

    $timePeriodSec = $timePeriodSec * -1
    $timeTruncatePrior = (Get-Date).AddSeconds($timePeriodSec)

    #On Server 2008/2012
    $colTrimmed = $col | Where-Object {$_.Timestamp -gt $timeTruncatePrior}
    
    #Works only on Server 2012
    #$colTrimmed = $col | Where-Object -Property $timeProperty -gt $timeTruncatePrior

    return ,$colTrimmed
}

Function get-LinearHashActivity {

$process = $Global:ProcessName_LinearHash

$lhc = Get-Counter ("\Process("+$process+")\*");

$r = New-Object PSObject
$r | Add-Member -Type NoteProperty -Name "Timestamp" -Value (Get-Date -format "yy/MM/dd HH:mm:ss").ToString()
$r | Add-Member -Type NoteProperty -Name "Iteration" -Value $Global:iterations

foreach($counter in $Global:counters){

        #write-host "Setting up counter" $counter

        $i = $counter
        $v = $lhc.CounterSamples | Where {$_.Path -like ("*" + $i)} | Select -ExpandProperty CookedValue
        $v = [math]::Round($v)
        #$v = "{0:N0}" -f $v
        $i = $i -replace "Bytes/sec","b/s"
        $i = $i -replace "Operations/sec","op/s"
        $i = $i -replace "IO ",""
        $i = $i -replace "% Processor Time","CPU %"

        #Useful for debugging if we want to generate stats based on the iteration count
        #to check if the interval averages calculate correctly
        #$v = $Global:iterations

        $r | Add-Member -Type NoteProperty -Name $i -Value $v

    }

    #Check if this loop should display the header row
    if ($Global:displayHeader -eq $false) {

        #For periodically showing the table headers
        if (
            ($displayHeaderInterval -gt 0) -and
            (($Global:iterations % $displayHeaderInterval) -eq 0)
        ) {
            $Global:displayHeader = $true
        } else {
            $Global:displayHeader = $false
        }
    }

    #Should the headers be displayed in this iterations output?
    if($Global:displayHeader -eq $true) {

            #Show the headers
            $outputRaw = $r | Format-Table -Property * -AutoSize 
            
            #Since the tabler headers were just displayed assume they won't be displayed again
            $Global:displayHeader = $false

        } else {

            #Hide the headers
            $outputRaw = $r | Format-Table -Property * -AutoSize -HideTableHeaders
            
    }

    #Add the current interval stat to the running averages
    [void]$Global:stats1min.add($r)
    [void]$Global:stats5min.add($r)

    #Display current interval stat if set
    if($displayRealtimeStats -eq $true) {
        $output = $outputRaw | Out-String
        #Trim trailing lines of the regular output so the table is tight
        $output = $output.Trim("`r`n")
        Write-Host $output
    }

    #Update the stats file with current interval stat
    
	#Append property only works on Server 2012
	#$r | Export-CSV -Path $Global:statsExportFilePath -noclobber -append -force
	
	#Append output to CSV file. Works on 2008/2012
	$CSVContent = $r | ConvertTo-Csv
    $CSVContent[2..$CSVContent.count] | add-content $Global:statsExportFilePath

    $timeEnd = Get-Date
    $timeRunningDuration = New-TimeSpan -Start $Global:timeStart1 -End $timeEnd
    $timeLastDisplayDuration = New-TimeSpan -Start $Global:timeDisplayLast -End $timeEnd

    if (($timeRunningDuration.TotalMinutes -gt 1) -and ($Global:avg1Displayed -eq $false)) {

        #Show the first 1 minute average stats since the last 5 minute average was displayed

        $statsToDisplay = trim-StatCollection -col $Global:stats1min -timePeriodSec (1 * 60)
        $toDisplay = calculateAverages -stats $statsToDisplay -desc "1 Min Interval"
        $toDisplay | Format-Table -Property * -AutoSize
        $Global:stats1min.Clear()

        $Global:avg1Displayed = $True
        $Global:timeDisplayLast = Get-Date    
    } else {

        if ($timeRunningDuration.TotalMinutes -gt 5) {

            #Show the 5 minute average stats

            $statsToDisplay = trim-StatCollection -col $Global:stats5min -timePeriodSec (5 * 60)
            $toDisplay = calculateAverages -stats $statsToDisplay -desc "5 Min Interval"
            $toDisplay | Format-Table -Property * -AutoSize
            $Global:stats5min.Clear()

            $Global:timeStart1 = Get-Date
            $Global:timeDisplayLast = Get-Date
            $Global:avg1Displayed = $False
        } else {

            if (($timeLastDisplayDuration.TotalMinutes -gt 1)) {
                
                #Show the additional 1 minute average stats

                
                $statsToDisplay = trim-StatCollection -col $Global:stats1min -timePeriodSec (1 * 60)
                $toDisplay = calculateAverages -stats $statsToDisplay -desc "1 Min Interval"
                $toDisplay | Format-Table -Property * -AutoSize
                $Global:stats1min.Clear()

                $Global:timeDisplayLast = Get-Date    
            }
        }
    }

    $Global:iterations = $Global:iterations + 1
}

#Controls when the 1 minute average stats
#have been displayed.
$avg1Displayed = $False

#Store when the last 1 minute average was displayed
$timeStart1 = Get-Date
$timeDisplayLast = $timeStart1

#Call function to find the EXE name of the installed LinearHash service.
$ProcessName_LinearHash = resolveLinearHashEXE

if ($ProcessName_LinearHash.length -eq 0) {
    write-host "No LinearHash service found."
    Exit
}

#Main processing loop
while ($true){

    #Call function to update all stats and display any output
    get-LinearHashActivity

    start-sleep 1

}