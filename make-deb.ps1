#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"

$Dist = Join-Path (Resolve-Path .) "./dist"
$Deb = Join-Path (Resolve-Path .) "./deb"

Remove-Item $Dist -Recurse -ErrorAction "Ignore"
Write-Host "Cleaned up artifacts"
New-Item $Dist -ItemType Directory | Out-Null

Push-Location $Dist
try {
	$NEVersion = "1.7.0"
	$NEHash = "a550cd5c05f760b7934a2d0afad66d2e92e681482f5f57a917465b1fba3b02a6"
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
	$Bin = Join-Path $DistDeb "opt/node-exporter"
	New-Item -ItemType Directory $Bin | Out-Null
	tar --extract --file $ArchiveName `
		--directory $Bin `
		--strip-components 1
	Write-Host "Extracted binaries"

	Get-ChildItem $Deb | Copy-Item -Destination $DistDeb -Recurse
	Write-Host "Copied predefined package files"

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