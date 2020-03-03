<#
  .SYNOPSIS
  Checks certificate thumbprints in DevOps release pipelines. Remember to update 
  the update the constants in this script to connect to DevOps.

  .DESCRIPTION
  This script will check all release definitions for a certificate
  thumbprint and verify this aginst the webserver.

  .INPUTS
  None. You cannot pipe objects to DevOps_release-definition_certificate_validation.ps1.

  .OUTPUTS
  DevOps_release-definition_certificate_validation.ps1 will output a 
  report of DevOps definitions with faulty certificate information.

  .EXAMPLE
  C:\PS> .\DevOps_release-definition_certificate_validation.ps1
  
  .NOTES
  For more info, please contact
  Thomas Karlson <thk@instinct.dk>
#>

$AzureDevOpsPAT   = "ENTER YOUR DEVOPS PAT HERE"
$OrganizationName = "YOUR DEVOPS ORG HERE"


function Get-RemoteCertificate () {
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $ComputerName,

    [int]
    $Port = 443
  )


  $Certificate = $null
  $TcpClient = New-Object -TypeName System.Net.Sockets.TcpClient
  try {

    $TcpClient.Connect($ComputerName,$Port)
    $TcpStream = $TcpClient.GetStream()

    $Callback = { param($sender,$cert,$chain,$errors) return $true }

    $SslStream = New-Object -TypeName System.Net.Security.SslStream -ArgumentList @($TcpStream,$true,$Callback)
    try {

      $SslStream.AuthenticateAsClient($ComputerName)
      $Certificate = $SslStream.RemoteCertificate

    } finally {
      $SslStream.Dispose()
    }

  }
  catch {
    #Write-Output "Not able to fetch certificate"
  }
  finally {
    $TcpClient.Dispose()
  }

  if ($Certificate) {
    if ($Certificate -isnot [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
      $Certificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Certificate
    }

    return $Certificate
  }

}

$AzureDevOpsAuthenicationHeader = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($AzureDevOpsPAT)")) }

$UriOrga = "https://dev.azure.com/$($OrganizationName)/"
$uriAccount = $UriOrga + "_apis/projects?api-version=5.1"

$Projects = (Invoke-RestMethod -Uri $uriAccount -Method get -Headers $AzureDevOpsAuthenicationHeader)

$Projects.value.ForEach({
    $uriAccount = "https://vsrm.dev.azure.com/$OrganizationName/$($_.id)/_apis/release/definitions?api-version=5.1"
    $ReleaseDefinitions = $(Invoke-RestMethod -Uri $uriAccount -Method get -Headers $AzureDevOpsAuthenicationHeader)

    $ReleaseDefinitions.value.ForEach({
        $ReleaseDefinition = $(Invoke-RestMethod -Uri $_.url -Method get -Headers $AzureDevOpsAuthenicationHeader)
        $ReleaseDefinition.environments.ForEach({
            $_.deployPhases.ForEach({
                $_.workflowTasks.ForEach({
                    if (($_.inputs.Bindings -ne $null) -and ($_.inputs.Bindings -ne '$(Parameters.Bindings)')) {
                      ($_.inputs.Bindings | ConvertFrom-Json).Bindings.Where({ $_.protocol -eq 'https' }).ForEach({

                          $cert = (Get-RemoteCertificate $_.hostname)
                          if ($cert -ne $null) {
                            if ($_.sslThumbprint.ToLower() -ne ($cert).Thumbprint.ToLower()) {
                              Write-Output "Problem with release definition ""$($ReleaseDefinition.name)"""
                              Write-Output "    Certificate thumbprint in release pipeline for the host ""$($_.hostname)"" is not identical to thumbprint installed on server!"
                              Write-Output "    Thumbprint in release pipeline         : $($_.sslThumbprint.ToLower())"
                              Write-Output "    Thumbprint in on installed certificate : $($cert.Thumbprint.ToLower())"
                              Write-Output "    FIX IT NOW: $($ReleaseDefinition._links.web.href) `n"
                            }

                            if ($cert.NotAfter -lt (Get-Date)) {
                              Write-Output "Problem with release definition ""$($ReleaseDefinition.name)"""
                              Write-Output "    Certificate on webserver with hostname ""$($_.hostname)"" has expired!"
                              Write-Output "    RENEW CERTIFICATE NOW! `n"
                            }
                          }
                          else {
                            Write-Output "Problem with release definition ""$($ReleaseDefinition.name)"""
                            Write-Output "    Unable to find certificate for host ""$($_.hostname)"" on webserver. Are you using a wrong hostname in your definition?"
                            Write-Output "    FIX IT NOW: $($ReleaseDefinition._links.web.href) `n"
                          }
                        })
                    }
                  })
              })
          })
      })
  })


