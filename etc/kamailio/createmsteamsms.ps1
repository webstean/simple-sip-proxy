
$sp = New-AzADServicePrincipal -DisplayName ServicePrincipalName

Connect-AzAccount -Identity
 

$userCredential = Get-Credential
$sfbSession = New-CsOnlineSession -Credential $userCredential
Import-PSSession $sfbSession

New-CsOnlinePSTNGateway -Fqdn SBC-DNS-DOMAIN -SipSignallingPort 5061 -MaxConcurrentSessions 10 -ForwardCallHistory $true -Enabled $true

Set-CsOnlinePstnUsage -Identity Global -Usage @{Add="Unrestricted"}

New-CsOnlineVoiceRoute -identity "Unrestricted" -NumberPattern ".*" -OnlinePstnGateway SBC-DNS-DOMAIN -Priority 1 -OnlinePstnUsages "Unrestricted"



