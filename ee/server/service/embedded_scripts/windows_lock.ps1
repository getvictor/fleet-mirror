# PowerShell script to log off all users and block all logons
#
# Record of the host's state before the lock: HKLM:\SOFTWARE\Fleet\WindowsLock
#   Version           (DWORD)       Layout of the record. Currently 2. Version 1 was the
#                                   original lock, which kept no record.
#   DenyInteractive   (String)      "Deny log on locally" value before the lock.
#   DenyRemote        (String)      "Deny log on through Remote Desktop Services" value before the lock.
#   SignInOptions     (String)      AllowSignInOptions value before the lock. Empty if it didn't exist.
#   DisabledAccounts  (MultiString) SIDs of the local accounts the lock disabled.
#
# windows_lock.ps1 writes the record and windows_unlock.ps1 reads it. The unlock
# that runs is the one in the Fleet server at that time, so a host locked today
# can be unlocked by a much newer script. Keep the record readable across versions:
#   - Never change what an existing field means. Add a new field instead.
#   - Treat a missing field as "not changed" and leave that setting alone.
#   - Keep unlock's fallback for hosts locked before this record existed.
#   - Bump Version for a change an older unlock could misread. Unlock refuses
#     a record with a newer Version than it knows, and keeps the record.

# Log off all users
$loggedOffUsers = @{}
Get-WmiObject -Class Win32_UserProfile | Where-Object { $_.Special -eq $false } | ForEach-Object {
    $username = $_.LocalPath.Split('\')[-1]
    if ($username -ne $env:USERNAME -and -not $loggedOffUsers.ContainsKey($username)) {
        try {
            $userSessions = query user | Where-Object { $_ -match "\b$username\b" }
            foreach ($session in $userSessions) {
                if ($session -match "\s+(\d+)\s+Disc\s+") {
                    # Disconnected sessions can't be logged off
                    continue
                }
                elseif ($session -match "\s+(\d+)\s+") {
                    $sessionID = $matches[1]
                    logoff $sessionID
                    $loggedOffUsers[$username] = $true
                    Write-Host "Logged out user: $username"
                }
            }
        } catch {
            Write-Host "Could not log off user: $username. Error: $($_.Exception.Message)"
        }
    }
}

# Deny Users (S-1-5-32-545) and Guests (S-1-5-32-546) groups with "Deny log on
# locally" and "Deny log on through Remote Desktop Services" policies to block
# every account type (local, AD, Azure/Entra) without touching cached logins.
# The previous values are saved so windows_unlock.ps1 can restore them.
$denyRights = 'SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight'

function Get-DenyLogonRights {
    $cfg = Join-Path $env:TEMP "fleet_user_rights_$([guid]::NewGuid()).inf"
    try {
        secedit /export /cfg $cfg /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit export failed with exit code $LASTEXITCODE" }
        $lines = @(Get-Content -Path $cfg)
    } finally {
        Remove-Item -Path $cfg -Force -ErrorAction SilentlyContinue
    }

    $result = @{}
    foreach ($right in $denyRights) {
        $match = $lines | Where-Object { $_ -match "^$right\s*=" } | Select-Object -First 1
        $result[$right] = if ($match) { ($match -replace "^$right\s*=\s*", '').Trim() } else { '' }
    }
    $result
}

# Sorted, so two lists compare equal whatever order secedit writes them in.
function ConvertTo-RightsList {
    param([string]$Value)

    (@($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) -join ',')
}

function Set-DenyLogonRights {
    param([hashtable]$Values)

    $id = [guid]::NewGuid().ToString()
    $cfg = Join-Path $env:TEMP "fleet_user_rights_$id.inf"
    $db = Join-Path $env:TEMP "fleet_user_rights_$id.sdb"

    try {
        secedit /export /cfg $cfg /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit export failed with exit code $LASTEXITCODE" }

        $lines = @(Get-Content -Path $cfg)
        foreach ($right in $denyRights) {
            $newLine = "$right = $($Values[$right])"
            if ($lines -match "^$right\s*=") {
                $lines = $lines | ForEach-Object { if ($_ -match "^$right\s*=") { $newLine } else { $_ } }
            } else {
                $lines = $lines | ForEach-Object { $_; if ($_ -eq '[Privilege Rights]') { $newLine } }
            }
        }
        $lines | Set-Content -Path $cfg -Encoding Unicode

        secedit /configure /db $db /cfg $cfg /areas USER_RIGHTS | Out-Null
        $configureExit = $LASTEXITCODE
    } finally {
        Remove-Item -Path $cfg, $db -Force -ErrorAction SilentlyContinue
    }

    # secedit can apply the rights and still exit non-zero with warnings (for
    # example, when it can't map an account), so check the result, not the exit code.
    $after = Get-DenyLogonRights
    foreach ($right in $denyRights) {
        if ((ConvertTo-RightsList $after[$right]) -ne (ConvertTo-RightsList $Values[$right])) {
            throw "$right is '$($after[$right])' instead of '$($Values[$right])' (secedit exit code $configureExit)"
        }
    }
    if ($configureExit -ne 0) { Write-Host "secedit exited with code $configureExit, but the rights are set." }
}

$stateKey = "HKLM:\SOFTWARE\Fleet\WindowsLock"
$signInKey = "HKLM:\Software\Microsoft\PolicyManager\default\Settings\AllowSignInOptions"
$denied = '*S-1-5-32-545,*S-1-5-32-546'
$rightsChanged = $false
try {
    $current = Get-DenyLogonRights

    # Remember which enabled local accounts we disable, so unlock only re-enables
    # those and not accounts that were already disabled (such as the built-in
    # Administrator and Guest).
    $accountsToDisable = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled -eq $true })

    # Save everything before changing anything, so a failed save leaves the host
    # untouched instead of locked with nothing to restore.
    if (-not (Test-Path $stateKey)) { New-Item -Path $stateKey -Force -ErrorAction Stop | Out-Null }
    $saved = Get-ItemProperty -Path $stateKey -ErrorAction SilentlyContinue
    # Don't overwrite the saved values if the host is locked twice.
    $snapshotSaved = ($null -ne $saved.DenyInteractive -and $null -ne $saved.DenyRemote)
    if (-not $snapshotSaved) {
        New-ItemProperty -Path $stateKey -Name DenyInteractive -Value $current['SeDenyInteractiveLogonRight'] -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $stateKey -Name DenyRemote -Value $current['SeDenyRemoteInteractiveLogonRight'] -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
    $originalRights = if ($snapshotSaved) {
        @{ SeDenyInteractiveLogonRight = $saved.DenyInteractive; SeDenyRemoteInteractiveLogonRight = $saved.DenyRemote }
    } else {
        $current
    }
    # An empty string means the value didn't exist before the lock.
    if ($null -eq $saved.SignInOptions) {
        $originalSignIn = (Get-ItemProperty -Path $signInKey -Name 'value' -ErrorAction SilentlyContinue).value
        # 3 is what this script sets, so it's left over from an earlier lock. Save the default instead.
        if ($originalSignIn -eq 3) { $originalSignIn = 1 }
        New-ItemProperty -Path $stateKey -Name SignInOptions -Value "$originalSignIn" -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
    # Merge with any earlier record so locking twice doesn't forget accounts.
    $sids = @(@($saved.DisabledAccounts) + ($accountsToDisable | ForEach-Object { $_.SID.Value }) | Where-Object { $_ } | Select-Object -Unique)
    New-ItemProperty -Path $stateKey -Name DisabledAccounts -Value $sids -PropertyType MultiString -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $stateKey -Name Version -Value 2 -PropertyType DWORD -Force -ErrorAction Stop | Out-Null

    $rightsChanged = $true
    Set-DenyLogonRights -Values @{ SeDenyInteractiveLogonRight = $denied; SeDenyRemoteInteractiveLogonRight = $denied }
    Write-Host "Logon denied for the Users and Guests groups."
} catch {
    Write-Host "Could not deny logon: $($_.Exception.Message)"
    # Don't leave the host half locked, which Fleet would report as not locked.
    if ($rightsChanged) {
        try {
            Set-DenyLogonRights -Values $originalRights
            Write-Host "Put the original logon rights back."
        } catch {
            Write-Host "Could not put the original logon rights back: $($_.Exception.Message)"
        }
    }
    exit 1
}

# The deny-logon policy above likely makes the next two steps redundant. They
# are kept as extra protection.

foreach ($account in $accountsToDisable) {
    Disable-LocalUser -SID $account.SID
    Write-Host "Disabled account for $($account.Name)"
}

# Disable additional AD logins
New-ItemProperty -Path $signInKey -Name 'value' -Value 3 -PropertyType DWORD -Force

Write-Host "All users have been logged out and their accounts disabled."
Write-Host "Logging in with other Microsoft accounts has been disabled"

# Restart computer in 15 seconds, after command has returned to Fleet
Write-Host "Restarting in 15 seconds"
shutdown /r /f /t 15
