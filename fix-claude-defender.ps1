# Excluye Claude Code de Windows Defender para evitar el timeout
# de "Subprocess initialization did not complete within 60000ms".
# REQUIERE permisos de administrador.

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Este script necesita permisos de administrador." -ForegroundColor Red
    Write-Host "Click derecho -> Ejecutar con PowerShell como administrador." -ForegroundColor Yellow
    Read-Host "Presiona Enter para cerrar"
    exit 1
}

$paths = @(
    "C:\Users\Manuel\.vscode\extensions\anthropic.claude-code-2.1.138-win32-x64",
    "C:\Users\Manuel\.claude",
    "C:\Users\Manuel\AppData\Roaming\npm\claude.cmd"
)

foreach ($p in $paths) {
    try {
        Add-MpPreference -ExclusionPath $p -ErrorAction Stop
        Write-Host "[OK] PATH excluido: $p" -ForegroundColor Green
    } catch {
        Write-Host "[ERR] $p -> $_" -ForegroundColor Red
    }
}

try {
    Add-MpPreference -ExclusionProcess "claude.exe" -ErrorAction Stop
    Write-Host "[OK] PROCESO excluido: claude.exe" -ForegroundColor Green
} catch {
    Write-Host "[ERR] claude.exe -> $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Estado final ===" -ForegroundColor Cyan
$prefs = Get-MpPreference
$prefs.ExclusionPath    | Where-Object { $_ -match "claude|anthropic" } | ForEach-Object { Write-Host "  PATH: $_" }
$prefs.ExclusionProcess | Where-Object { $_ -match "claude" }           | ForEach-Object { Write-Host "  PROC: $_" }

Write-Host ""
Write-Host "Listo. Reinicia VSCode para que tome efecto." -ForegroundColor Yellow
Read-Host "Presiona Enter para cerrar"
