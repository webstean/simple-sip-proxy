
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass


Install-Module MicrosoftTeams
Connect-MicrosoftTeams -UseDeviceAuthentication

Get-CsTenant
Get-Team | Sort DisplayName


Update-Module MicrosoftTeams
New-CsOnlinePSTNGateway -Fqdn SBC-DNS-DOMAIN.test.org -SipSignalingPort 5061 -MaxConcurrentSessions 10 -ForwardCallHistory $true -Enabled $true

Set-CsOnlinePstnUsage -Identity Global -Usage @{Add="Unrestricted"}

New-CsOnlineVoiceRoute -identity "Unrestricted" -NumberPattern ".*" -OnlinePstnGateway SBC-DNS-DOMAIN -Priority 1 -OnlinePstnUsages "Unrestricted"



