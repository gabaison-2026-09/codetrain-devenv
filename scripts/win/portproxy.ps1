# WSL2 が NAT モードのときに、Windows 側から WSL 内のサービスへ届かせるための
# ポートフォワード設定（Document/LOCAL_DEV.md §2.2 方法B）。
#
# 方法A（.wslconfig の networkingMode=mirrored）が使えるなら、そちらを優先すること。
# ミラーモードなら本スクリプトは不要。
#
# 使い方: **管理者権限の PowerShell** で実行する。
#   .\scripts\win\portproxy.ps1
#
# 注意: NAT モードでは WSL2 の IP が再起動のたびに変わる。
#       WSL を起動し直すたびに実行する運用になる（§11「昨日まで動いていたのに繋がらない」）。

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# 転送するポート:
#   8080 = api（コンテナ。Flutter エミュレータからは 10.0.2.2:8080）
#   3000 = admin（WSL ホストの next dev。コンテナではない）
$ports = @(8080, 3000)

$wslIp = (wsl hostname -I).Trim().Split(" ")[0]
if (-not $wslIp) {
    throw "WSL の IP を取得できませんでした。WSL が起動しているか確認してください。"
}
Write-Host "WSL2 IP: $wslIp"

foreach ($port in $ports) {
    # 既存の設定を消してから入れ直す（IP が変わっているため）
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 2>$null | Out-Null
    netsh interface portproxy add v4tov4 `
        listenport=$port listenaddress=0.0.0.0 `
        connectport=$port connectaddress=$wslIp | Out-Null
    Write-Host "  0.0.0.0:$port -> ${wslIp}:$port"
}

Write-Host ""
netsh interface portproxy show v4tov4

Write-Host ""
Write-Host "実機（同一 LAN の Android 端末）から繋ぐ場合は、加えて Windows Defender"
Write-Host "ファイアウォールで上記ポートの受信を許可し、接続先には Windows の LAN IP を使う。"
