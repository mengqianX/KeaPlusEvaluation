# PowerShell 脚本 - dump_coverage.ps1

param (
    [string]$AVD_SERIAL,
    [string]$APP_PACKAGE_NAME,
    [string]$OUTPUT_DIR,
    [string]$RECEIVER_NAME
)

if (-not $AVD_SERIAL -or -not $APP_PACKAGE_NAME -or -not $OUTPUT_DIR) {
    Write-Output "Usage: dumpCoverage.ps1 <AVD_SERIAL> <APP_PACKAGE_NAME> <OUTPUT_DIR>"
    exit
}

# 初始化变量
$i = 0

# 无限循环，定期转储覆盖率数据
while ($true) {
    $i++
    Start-Sleep -Seconds 300  # 每5分钟转储一次覆盖率数据

    & adb -s $AVD_SERIAL shell am broadcast -a edu.gatech.m3.emma.COLLECT_COVERAGE -n $RECEIVER_NAME
    & adb -s $AVD_SERIAL pull /data/user/0/$APP_PACKAGE_NAME/files/coverage.ec $OUTPUT_DIR/coverage_$i.ec
    & adb -s $AVD_SERIAL shell rm /data/user/0/$APP_PACKAGE_NAME/files/coverage.ec
}
