Set-StrictMode -Version 2.0

# Deliberately limited to visible artisan test / phpunit / paratest invocations.
# This is not a shell sandbox: aliases, scripts and dynamically built commands
# remain subject to the worker protocol. Never execute command text to inspect it.
function Test-FactoryDatabaseTestInvocation {
    param([string[]]$Words)
    if (-not $Words.Count) { return $false }
    $executable = ($Words[0] -split '[/\\]')[-1]
    if ($executable -match '^(?i:phpunit|paratest)(?:\.(?:phar|exe|bat|cmd))?$') { return $true }
    if ($executable -match '^(?i:php)(?:\.exe)?$') {
        for ($i = 1; $i -lt $Words.Count; $i++) {
            $file = ($Words[$i] -split '[/\\]')[-1]
            if ($file -match '^(?i:phpunit|paratest)(?:\.phar)?$') { return $true }
            if ($file -eq 'artisan' -and $i + 1 -lt $Words.Count -and $Words[$i + 1] -eq 'test') { return $true }
        }
    }
    return $executable -eq 'artisan' -and $Words.Count -gt 1 -and $Words[1] -eq 'test'
}

function Assert-FactoryPinnedTestDatabase {
    param($Task, [string]$Variable, [string]$Expected, [string]$Actual, [string]$Source)
    if ($Actual -ceq $Expected) { return }
    throw ("Factory test-command guard: task '$($Task.id)' must explicitly pin $Variable to '$Expected' in each test invocation (Bash inline assignment, or an earlier literal PowerShell environment assignment in the same command).`n" +
        (Format-FactoryWorkerGuardDiagnostic -Expected $Expected -Actual $Actual -Source $Source))
}

function Assert-FactoryNestedTestCommand {
    param($Task, $DatabaseSettings, [string[]]$Words, [int]$Depth)
    if ($Words.Count -lt 3) { return }
    $executable = ($Words[0] -split '[/\\]')[-1]
    $shell = ''
    $switches = @()
    if ($executable -match '^(?i:powershell|pwsh)(?:\.exe)?$') {
        $shell = 'PowerShell'; $switches = @('-Command', '-c')
    } elseif ($executable -match '^(?:bash|sh)(?:\.exe)?$') {
        $shell = 'Bash'; $switches = @('-c', '-lc')
    }
    if (-not $shell) { return }
    for ($i = 1; $i -lt $Words.Count - 1; $i++) {
        if ($Words[$i] -in $switches) {
            Assert-FactoryWorkerTestCommand -Task $Task -DatabaseSettings $DatabaseSettings -Command $Words[$i + 1] -ToolName $shell -Depth ($Depth + 1)
            return
        }
    }
}

function Assert-FactoryWorkerTestCommand {
    param($Task, $DatabaseSettings, [string]$Command, [string]$ToolName = 'Bash', [int]$Depth = 0)
    if ($null -eq $DatabaseSettings) { return }
    $variable = [string]$DatabaseSettings.databaseEnvironmentVariable
    $expected = Get-FactoryTestDatabaseName -Settings $DatabaseSettings -Scope worker -TaskId ([string]$Task.id)
    if ($Depth -gt 8) {
        Assert-FactoryPinnedTestDatabase $Task $variable $expected '<unverified nested shell>' 'tool_input.command'
    }

    if ($ToolName -eq 'PowerShell') {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
        $assignments = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst]
        }, $true) | Where-Object { $_.Left.VariablePath.UserPath -ieq "env:$variable" })
        foreach ($invocation in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
            $words = @($invocation.CommandElements | ForEach-Object {
                if ($_ -is [Management.Automation.Language.StringConstantExpressionAst]) { [string]$_.Value }
                elseif ($_ -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $_.NestedExpressions.Count -eq 0) { [string]$_.Value }
                else { [string]$_.Extent.Text }
            })
            if (Test-FactoryDatabaseTestInvocation $words) {
                $actual = ''
                $prior = @($assignments | Where-Object { $_.Extent.EndOffset -lt $invocation.Extent.StartOffset } | Sort-Object { $_.Extent.StartOffset } -Descending | Select-Object -First 1)
                if ($prior.Count) {
                    # The assignment must dominate this command, not live in an
                    # earlier conditional branch/function that might never run.
                    $ancestor = $invocation.Parent
                    while ($null -ne $ancestor -and -not [object]::ReferenceEquals($ancestor, $prior[0].Parent)) { $ancestor = $ancestor.Parent }
                    if ($null -ne $ancestor -and [string]$prior[0].Operator -eq 'Equals') {
                        if ($prior[0].Right -is [Management.Automation.Language.CommandExpressionAst] -and
                            $prior[0].Right.Expression -is [Management.Automation.Language.StringConstantExpressionAst]) {
                            $actual = [string]$prior[0].Right.Expression.Value
                        } else { $actual = '<nonliteral>' }
                    } else { $actual = '<conditional or unverified assignment>' }
                }
                if ($errors.Count) { $actual = '<unparseable PowerShell command>' }
                Assert-FactoryPinnedTestDatabase $Task $variable $expected $actual "tool_input.command PowerShell $variable"
            }
            Assert-FactoryNestedTestCommand $Task $DatabaseSettings $words $Depth
        }
        return
    }

    # Keep quoted text/comments out of command-position matching. Each Bash
    # invocation needs its own inline pin; a pin for `echo` cannot bless a later
    # phpunit, and a pipe/semicolon starts a new command with no inherited proof.
    $pattern = '(?<comment>\#[^\r\n]*)|(?<separator>&&|\|\||[;&|()\r\n])|(?<word>(?:''[^'']*''|"(?:\\.|[^"\\])*"|\\[\s\S]|[^\s;&|()''"])+)'
    $segments = New-Object Collections.Generic.List[object]
    $words = New-Object Collections.Generic.List[string]
    $hereDocuments = New-Object Collections.Generic.List[string]
    $awaitingDelimiter = $false; $skipUntil = 0
    $shellText = $Command -replace '\\\r?\n', ''
    foreach ($token in [regex]::Matches($shellText, $pattern)) {
        if ($token.Index -lt $skipUntil) { continue }
        if ($token.Groups['comment'].Success) { continue }
        if ($token.Groups['separator'].Success) {
            if ($words.Count) { $segments.Add($words.ToArray()); $words.Clear() }
            if ($token.Value -match '[\r\n]' -and $hereDocuments.Count) {
                # A heredoc is stdin data (often documentation), not shell code.
                $skipUntil = $token.Index + $token.Length
                foreach ($delimiter in $hereDocuments) {
                    $end = [regex]::Match($shellText.Substring($skipUntil), '(?m)^\t*' + [regex]::Escape($delimiter) + '\r?$')
                    $skipUntil = if ($end.Success) { $skipUntil + $end.Index + $end.Length } else { $shellText.Length }
                }
                $hereDocuments.Clear()
            }
        } else {
            $word = [regex]::Replace($token.Value, "(['" + '"' + "])(.*?)\1", '$2')
            if ($awaitingDelimiter) { $hereDocuments.Add($word); $awaitingDelimiter = $false }
            elseif ($token.Value -match '^<<-?$') { $awaitingDelimiter = $true }
            elseif ($token.Value -match '^<<-?[^<]') { $hereDocuments.Add(($word -replace '^<<-?', '')) }
            if ($word -notin @('{', '}')) { $words.Add($word) }
        }
    }
    if ($words.Count) { $segments.Add($words.ToArray()) }
    foreach ($segment in $segments) {
        $index = 0; $actual = ''
        while ($index -lt $segment.Count -and $segment[$index] -in @('then', 'do', 'if', 'elif', 'while', 'until', '!', 'time')) { $index++ }
        if ($index -lt $segment.Count -and ($segment[$index] -split '/')[-1] -eq 'env') {
            $index++
            while ($index -lt $segment.Count -and $segment[$index].StartsWith('-')) {
                if ($segment[$index] -in @('-u', '--unset')) { $index += 2 } else { $index++ }
            }
        }
        while ($index -lt $segment.Count -and $segment[$index] -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            if ($Matches[1] -ceq $variable) { $actual = $Matches[2] }
            $index++
        }
        if ($index -ge $segment.Count) { continue }
        $invocation = @($segment[$index..($segment.Count - 1)])
        if (Test-FactoryDatabaseTestInvocation $invocation) {
            Assert-FactoryPinnedTestDatabase $Task $variable $expected $actual "tool_input.command Bash $variable"
        }
        Assert-FactoryNestedTestCommand $Task $DatabaseSettings $invocation $Depth
    }
}
