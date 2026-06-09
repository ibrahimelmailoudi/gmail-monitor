# fix-git.ps1 - fix the git lock, add .gitignore, stop committing node_modules/.env
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"

# 1) Remove the stale lock left by the crashed git process
if (Test-Path ".git\index.lock") {
  Remove-Item ".git\index.lock" -Force
  Write-Host "Removed stale .git\index.lock"
}

# 2) Write the root .gitignore (note the leading dot - exact name matters)
Set-Content -LiteralPath ".gitignore" -Encoding utf8 -Value @'
# dependencies (re-installed by the host, never commit)
node_modules/
**/node_modules/

# secrets - NEVER commit these
.env
**/.env
*.env
!**/.env.example

# build output
dist/
build/
**/dist/

# logs / local data
*.log
npm-debug.log*
backend/data.json

# OS / editor junk
.DS_Store
Thumbs.db
.vscode/
.idea/
'@
Write-Host "Wrote .gitignore"

# 3) Un-stage EVERYTHING currently staged (so we start clean), then re-add
#    only the files git should track (node_modules/.env now ignored).
git reset
git rm -r --cached --quiet node_modules 2>$null
git rm -r --cached --quiet backend/node_modules 2>$null
git rm -r --cached --quiet frontend/node_modules 2>$null
git rm --cached --quiet backend/.env 2>$null
git rm --cached --quiet .env 2>$null

# 4) Stage the real project files (gitignore now excludes the junk)
git add -A

Write-Host ""
Write-Host "Done. Now check what WILL be committed:"
Write-Host "   git status"
Write-Host ""
Write-Host "You should NOT see node_modules or .env in the list."
Write-Host "If it looks right:"
Write-Host '   git commit -m "deploy prep"'
