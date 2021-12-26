#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"

$Dist = Resolve-Path "./dist"
$Deb = Resolve-Path "./deb"

Remove-Item $Dist -Recurse -ErrorAction "Ignore"
Write-Host "Cleaned up artifacts"
New-Item $Dist -ItemType Directory | Out-Null

Push-Location $Dist
try {
	$NEVersion = "1.3.1"
	$NEHash = "68f3802c2dd3980667e4ba65ea2e1fb03f4a4ba026cca375f15a0390ff850949"
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

	# TODO: Verify permissions are correct upon installation

	New-Item -ItemType Directory "deb/opt" | Out-Null
	tar --extract --file $ArchiveName `
		--directory "deb/opt" `
		--strip-components 1
	Write-Host "Extracted binaries"

	Get-ChildItem $Deb | Copy-Item -Destination "deb" -Recurse
	Write-Host "Copied predefined package files"

	$Package = "node-exporter.deb"
	dpkg-deb --build `
		--root-owner-group `
		deb `
		node-exporter.deb
	Write-Host "Built deb-package"
	Get-ChildItem $Package
}
finally {
	Pop-Location
}