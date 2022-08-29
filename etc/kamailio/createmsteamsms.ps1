$userCredential = Get-Credential
$sfbSession = New-CsOnlineSession -Credential $userCredential
Import-PSSession $sfbSession

New-CsOnlinePSTNGateway -Fqdn SBC-DNS-DOMAIN -SipSignallingPort 5061 -MaxConcurrentSessions 10 -ForwardCallHistory $true -Enabled $true
