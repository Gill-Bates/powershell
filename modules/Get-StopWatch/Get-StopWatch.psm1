function Get-StopWatch {
    if (!$StopWatch.IsRunning) {
        return "n/a"
    }
    if ($StopWatch.Elapsed.Days -ne 0) {
        return "$($StopWatch.Elapsed.Days) days !!!" 
    }
    if ($StopWatch.Elapsed.Hours -eq 0 -and $StopWatch.Elapsed.Minutes -ne 0) {
        $TimeResult = [math]::round($Stopwatch.Elapsed.TotalMinutes, 2)
        return "$TimeResult Minutes" 
    }
    if ($StopWatch.Elapsed.Hours -eq 0 -and $StopWatch.Elapsed.Minutes -eq 0) {
        $TimeResult = [math]::round($Stopwatch.Elapsed.TotalSeconds, 0)
        return "$TimeResult seconds" 
    }
}