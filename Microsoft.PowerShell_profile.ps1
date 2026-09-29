oh-my-posh init pwsh --config "spaceship" | Invoke-Expression

(&mise activate pwsh) | Out-String | Invoke-Expression

$env:PYTHONDONTWRITEBYTECODE = "1"
$env:UE_DIR = "C:\Program Files\Epic Games\UE_5.8"
 
function dot {
    Set-Location "E:\Dev\dotfiles"
}

function prof {
    nvim ~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1
}
