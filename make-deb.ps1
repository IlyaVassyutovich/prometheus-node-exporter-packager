#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"

$Dist = Join-Path (Resolve-Path .) "./dist"
$Deb = Join-Path (Resolve-Path .) "./deb"

Remove-Item $Dist -Recurse -ErrorAction "Ignore"
Write-Host "Cleaned up artifacts"
New-Item $Dist -ItemType Directory | Out-Null

Push-Location $Dist
try {
	$NEVersion = "1.8.2"
	$NEHash = "6809dd0b3ec45fd6e992c19071d6b5253aed3ead7bf0686885a51d85c6643c66"
	$ArchiveName = "node_exporter.tar.gz"

	Invoke-WebRequest "https://github.com/prometheus/node_exporter/releases/download/v$NEVersion/node_exporter-$NEVersion.linux-amd64.tar.gz" `
		-OutFile $ArchiveName
	Write-Host "Downloaded exporter ($NEVersion)"

	$CurrentHash = (Get-FileHash -Path $ArchiveName -Algorithm SHA256).Hash
	if ($NEHash -ne $CurrentHash) {
		throw "Hashes does not match"
	}
	else {
		Write-Host "Checked hashes"
	}

	$DistDeb = Join-Path (Get-Location) "./deb"
	Copy-Item -Recurse -Path $Deb -Destination $DistDeb
	Write-Host "Copied predefined package files"

	$Bin = Join-Path $DistDeb "opt/node-exporter"
	tar --extract --file $ArchiveName `
		--directory $Bin `
		--strip-components 1
	Write-Host "Extracted binaries"

	$Package = "node-exporter.deb"
	dpkg-deb --build `
		--root-owner-group `
		"deb" `
		"node-exporter.deb"
	Write-Host "Built deb-package"
	Get-ChildItem $Package
}
finally {
	Pop-Location
}