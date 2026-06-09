$rg = "rg-isbankag-network-core-gw"
$appgwName = "appgw-isbankag-prod"
$outFile = "pg-all-rules_and_listeners.csv"

$appgw = Get-AzApplicationGateway -ResourceGroupName $rg -Name $appgwName
$result = @()

foreach ($rule in $appgw.RequestRoutingRules | Where-Object { $_.Name -match "pg" }) {

    $listenerName = ($rule.HttpListener.Id -split "/")[-1]
    $listener = $appgw.HttpListeners | Where-Object { $_.Name -eq $listenerName }

    $hostNames =
        if ($listener.HostNames) {
            $listener.HostNames -join ","
        } elseif ($listener.HostName) {
            $listener.HostName
        } else {
            "<none>"
        }

    $redirectUrl = $null

    # -------- Redirect (rule level) --------
    if ($rule.RedirectConfiguration) {
        $redirName = ($rule.RedirectConfiguration.Id -split "/")[-1]
        $redir = $appgw.RedirectConfigurations | Where-Object { $_.Name -eq $redirName }

        if ($redir.TargetUrl) {
            $redirectUrl = $redir.TargetUrl
        } elseif ($redir.TargetListener) {
            $redirectUrl = "listener://" + (($redir.TargetListener.Id -split "/")[-1])
        }
    }

    # -------- PATH BASED --------
    if ($rule.RuleType -eq "PathBasedRouting" -and $rule.UrlPathMap) {

        $pathMapName = ($rule.UrlPathMap.Id -split "/")[-1]
        $pathMap = $appgw.UrlPathMaps | Where-Object { $_.Name -eq $pathMapName }

        # default redirect (çok kritik)
        if ($pathMap.DefaultRedirectConfiguration) {
            $redirName = ($pathMap.DefaultRedirectConfiguration.Id -split "/")[-1]
            $redir = $appgw.RedirectConfigurations | Where-Object { $_.Name -eq $redirName }

            if ($redir.TargetUrl) {
                $redirectUrl = $redir.TargetUrl
            } elseif ($redir.TargetListener) {
                $redirectUrl = "listener://" + (($redir.TargetListener.Id -split "/")[-1])
            }
        }

        foreach ($pr in $pathMap.PathRules) {
            foreach ($p in $pr.Paths) {
                $result += [PSCustomObject]@{
                    RuleType     = "PathBased"
                    RuleName     = $rule.Name
                    ListenerName = $listenerName
                    HostNames    = $hostNames
                    Path         = $p
                    TargetURL    = $redirectUrl
                }
            }
        }
    }

    # -------- BASIC --------
    if ($rule.RuleType -eq "Basic") {
        $result += [PSCustomObject]@{
            RuleType     = "Basic"
            RuleName     = $rule.Name
            ListenerName = $listenerName
            HostNames    = $hostNames
            Path         = "<basic>"
            TargetURL    = $redirectUrl
        }
    }
}

$result | Export-Csv $outFile -NoTypeInformation -Encoding UTF8
