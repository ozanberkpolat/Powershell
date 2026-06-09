$rg = "rg-isbankag-network-core-gw"
$appgwName = "appgw-isbankag-prod"
$outFile = "pg-all-rules.csv"

$appgw = Get-AzApplicationGateway -ResourceGroupName $rg -Name $appgwName
$result = @()

foreach ($rule in $appgw.RequestRoutingRules | Where-Object { $_.Name -match "pg" }) {

    $listenerName = ($rule.HttpListener.Id -split "/")[-1]
    $redirectUrl = $null

    # ---------- Redirect resolve (Rule level) ----------
    if ($rule.RedirectConfiguration) {
        $redirName = ($rule.RedirectConfiguration.Id -split "/")[-1]
        $redir = $appgw.RedirectConfigurations | Where-Object { $_.Name -eq $redirName }

        if ($redir.TargetUrl) {
            $redirectUrl = $redir.TargetUrl
        } elseif ($redir.TargetListener) {
            $redirectUrl = "listener://" + (($redir.TargetListener.Id -split "/")[-1])
        }
    }

    # ---------- PATH BASED ----------
    if ($rule.RuleType -eq "PathBasedRouting" -and $rule.UrlPathMap) {

        $pathMapName = ($rule.UrlPathMap.Id -split "/")[-1]
        $pathMap = $appgw.UrlPathMaps | Where-Object { $_.Name -eq $pathMapName }

        # Default redirect (çok kritik)
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
                    Path         = $p
                    TargetURL    = $redirectUrl
                }
            }
        }
    }

    # ---------- BASIC ----------
    if ($rule.RuleType -eq "Basic") {
        $result += [PSCustomObject]@{
            RuleType     = "Basic"
            RuleName     = $rule.Name
            ListenerName = $listenerName
            Path         = "<basic>"
            TargetURL    = $redirectUrl
        }
    }
}

$result | Export-Csv $outFile -NoTypeInformation -Encoding UTF8
