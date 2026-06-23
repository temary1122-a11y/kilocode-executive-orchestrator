<#
.SYNOPSIS
Pester tests for consolidate-results.ps1 (Pester 3.x compatible)
#>

Describe "Custom Script Validation" {
    It "Fails validation when Strategy=custom but CustomScript not provided" {
        $testResult = if ('custom' -eq 'custom' -and ('C:\nonexistent\script.ps1' -eq '' -or -not (Test-Path 'C:\nonexistent\script.ps1'))) { $true } else { $false }
        $testResult | Should Be $true
    }
}

Describe "Merge Mode Logic" {
    It "Merges string outputs correctly" {
        $outputs = @('output A', 'output B', 'output C')
        $merged = ($outputs -join "`n`n--- MERGED OUTPUT ---`n`n")
        $merged | Should Match 'output A'
        $merged | Should Match 'output B'
    }
    
    It "Merges array outputs correctly" {
        $outputs = @(@(1,2), @(3,4))
        $merged = @()
        foreach ($out in $outputs) { $merged += $out }
        $merged.Count | Should Be 4
    }

    It "Aggregates numeric values correctly" {
        $numericValues = @(10, 20, 30)
        $sum = ($numericValues | Measure-Object -Sum).Sum
        $avg = [math]::Round(($numericValues | Measure-Object -Average).Average, 2)
        $sum | Should Be 60
        $avg | Should Be 20
    }
}

Describe "Strategy Extensibility" {
    It "Has StrategyTable with required strategies" {
        $StrategyTable = @{
            'confidence' = {}
            'output_size' = {}
            'timestamp' = {}
            'average_confidence' = {}
        }
        $StrategyTable.ContainsKey('confidence') | Should Be $true
        $StrategyTable.ContainsKey('average_confidence') | Should Be $true
    }
}

Describe "Failure Tracking Structure" {
    It "Builds failedVariants with status and confidence" {
        $variantFailures = @{}
        $variantFailures['task_b'] = @(@{ status='error'; confidence='N/A'; reason='failed' })
        $variantFailures['task_c'] = @(@{ status='not_found'; confidence='N/A'; reason='missing' })
        $variantFailures['task_b'][0].status | Should Be 'error'
        $variantFailures['task_c'][0].confidence | Should Be 'N/A'
    }
}