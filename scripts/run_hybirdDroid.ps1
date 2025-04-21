param (
    [string]$APK_PATH,
    [string]$DEVICE_SERIAL,
    [string]$AVD_NAME,
    [string]$OUTPUT_PATH,
    [string]$TEST_TIME,
    [string]$EVENT_COUNT
)

$PYTHON_SCRIPT = ".\start.py"
$HEADLESS = $false
# 获取当前日期时间
$current_date_time = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
# 获取 APK 文件的基本名称
$apk_file_name = [System.IO.Path]::GetFileName($APK_PATH)
$RESULT_DIR = Join-Path $OUTPUT_PATH "$apk_file_name.hybirddroid.result.$DEVICE_SERIAL.$AVD_NAME#$current_date_time"
$LOG_FILE = $RESULT_DIR + "\log.txt"

# 使用正则表达式提取端口号
if ($DEVICE_SERIAL -match 'emulator-(\d+)') {
    $AVD_PORT = $matches[1]
    Write-Output "The port is: $AVD_PORT"
} else {
    Write-Output "No port found in the string."
}

# 确保输出目录存在
function Ensure-DirectoryExists {
    param (
        [string]$Directory
    )
    if (-not (Test-Path -Path $Directory -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $Directory -ErrorAction Stop
            Write-Output "Directory '$Directory' created successfully."
        } catch {
            Write-Output "Failed to create directory '$Directory'. Error: $_"
        }
    } else {
        Write-Output "Directory '$Directory' already exists."
    }
}
Ensure-DirectoryExists -Directory $RESULT_DIR

# 检查模拟器是否已经启动
function IsEmulatorRunning {
    param (
        [string]$port
    )
    $adbOutput = & adb devices
    return $adbOutput -match "emulator-$port"
}

# 启动模拟器
function StartEmulator {
    param (
        [string]$avdName,
        [string]$port,
        [bool]$headless
    )
    $headlessFlag = ""
    if ($headless) {
        $headlessFlag = "-no-window"
    }
    Start-Process -FilePath "emulator" -ArgumentList ("-port $port -avd $avdName -read-only $headlessFlag") -NoNewWindow -PassThru
}

# 等待设备准备好
function WaitForDevice {
    param (
        [string]$deviceSerial
    )
    Write-Output "Waiting for device $deviceSerial to be ready..."
    & adb -s $deviceSerial wait-for-device -Timeout 5s
    $bootAnimStatus = & adb -s $deviceSerial shell getprop init.svc.bootanim
    $i = 0
    while ($bootAnimStatus.Trim() -ne 'stopped') {
        Write-Output "   Waiting for emulator ($deviceSerial) to fully boot (#$i times) ..."
        Start-Sleep -Seconds 5
        $i++
        if ($i -eq 10) {
            Write-Output "Cannot connect to the device: ($deviceSerial) after (#$i times)..."
            break
        }
        $bootAnimStatus = & adb -s $deviceSerial shell getprop init.svc.bootanim
    }
    if ($bootAnimStatus.Trim() -eq 'stopped') {
        Write-Output "Device $deviceSerial is fully booted."
    }
}

$RETRY_TIMES=5
$try=0
# 判断设备是否启动，如果已经启动则杀死
while ( -not (IsEmulatorRunning -port $AVD_PORT)) {
    if($try -eq $RETRY_TIMES){
        Write-Output "we give up the emulator"
        exit
    }
    Write-Output "try to start the emulator ($DEVICE_SERIAL)..."
    Start-Sleep -Seconds 5

    # start the emulator
    StartEmulator -avdName $AVD_NAME -port $AVD_PORT -headless $HEADLESS
    Start-Sleep -Seconds 5
    # wait for the emulator
    WaitForDevice -deviceSerial $DEVICE_SERIAL
    Start-Sleep -Seconds 5
    $try++
}


# 获取应用包名
$packageInfo = & aapt dump badging $APK_PATH
$PACKAGE_NAME = $packageInfo | Select-String -Pattern "package: name='" | ForEach-Object {
    $_.Line -replace ".*package: name='([^']*)'.*", '$1'
}
# 注意正则匹配规则
Write-Output "** PROCESSING APP (${DEVICE_SERIAL}): $PACKAGE_NAME"

Write-Output "emulator ($DEVICE_SERIAL) is booted!"
# 授予权限
& adb -s  $DEVICE_SERIAL root

# 检查设备连接状态
Write-Output "** CHECKING DEVICE CONNECTION ($DEVICE_SERIAL)"
$device = & adb devices | Select-String $DEVICE_SERIAL
if (-not $device) {
    Write-Output "Device $DEVICE_SERIAL not connected."
    exit 1
}

# 最大重试次数
$MAX_RETRIES = 3
# 当前尝试次数
$attempt = 0
# 有时候droidbot会因为无法清除日志而启动失败，加-d可以解决这个问题
# 重复尝试执行命令
while ($attempt -lt $MAX_RETRIES) {
    # 尝试执行命令
    adb -s $DEVICE_SERIAL logcat -c -d
    # 检查命令执行结果
    if ($LASTEXITCODE -eq 0) {
        Write-Output "success"
        break
    } else {
        $attempt++
        Write-Output "failed,retry $attempt Times."
    }
    Start-Sleep -Seconds 1
}

# 安装应用并自动授予权限
&adb -s $DEVICE_SERIAL install -g $APK_PATH
Start-Sleep -Seconds 2

#anroid 11 通过以下命令授予存储权限
&adb -s $DEVICE_SERIAL shell appops set --uid $PACKAGE_NAME MANAGE_EXTERNAL_STORAGE allow
Start-Sleep -Seconds 2

# 获取注册的广播接收器名称
$RECEIVER_NAME=$(adb -s $DEVICE_SERIAL shell pm dump $PACKAGE_NAME | grep "jacocoInstrument.SMSInstrumentedReceiver" | awk '{print $2}')
# 打印获取到的接收器名称
Write-Output "Registered Broadcast Receiver: $RECEIVER_NAME"

Start-Sleep -Seconds 2


# 启动覆盖率数据转储
Write-Output "** START COVERAGE ($DEVICE_SERIAL)"
Start-Process -FilePath "powershell" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "dump_coverage.ps1", $DEVICE_SERIAL, $PACKAGE_NAME, $RESULT_DIR, $RECEIVER_NAME -NoNewWindow -PassThru
Write-Output "Coverage dump started in background"

& adb -s $DEVICE_SERIAL shell date "+%Y-%m-%d-%H:%M:%S" | Out-File -FilePath "$RESULT_DIR/hybirddroid_testing_time_on_emulator.txt" -Encoding utf8

# 运行Python脚本并传递参数
if($TEST_TIME -ne "None"){
    & python3 $PYTHON_SCRIPT -d $DEVICE_SERIAL -a $APK_PATH -o $RESULT_DIR -timeout $TEST_TIME -grant_perm -is_emulator 2>&1 | Tee-Object -FilePath $LOG_FILE -Append
}
elseif($EVENT_COUNT -ne "None"){
    & python3 $PYTHON_SCRIPT -d $DEVICE_SERIAL -a $APK_PATH -o $RESULT_DIR -count $EVENT_COUNT -grant_perm -is_emulator 2>&1 | Tee-Object -FilePath $LOG_FILE -Append

}

& adb -s $DEVICE_SERIAL shell date "+%Y-%m-%d-%H:%M:%S" | Out-File -FilePath "$RESULT_DIR/hybirddroid_testing_time_on_emulator.txt" -Encoding utf8 -Append

# 停止覆盖率数据转储
Write-Output "** STOP COVERAGE ($DEVICE_SERIAL)"
$coverage_pid = Get-Process | Where-Object { $_.Path -eq "powershell" -and $_.CommandLine -like "*dump_coverage.ps1 $DEVICE_SERIAL*" } | Select-Object -ExpandProperty Id
if ($coverage_pid) {
    Stop-Process -Id $coverage_pid
}

# 停止 logcat
Write-Output "** STOP LOGCAT ($DEVICE_SERIAL)"
$logcat_pid = Get-Process | Where-Object { $_.Path -eq "adb" -and $_.CommandLine -like "*$DEVICE_SERIAL logcat*" } | Select-Object -ExpandProperty Id
if ($logcat_pid) {
    Stop-Process -Id $logcat_pid
}

# 删除AnkiDroid数据
if($PACKAGE_NAME -eq "com.ichi2.anki"){
    & adb -s $DEVICE_SERIAL shell rm -rf /sdcard/AnkiDroid
    & adb -s $DEVICE_SERIAL shell rm -rf /sdcard/Android/com.ichi2.anki
}

# 关闭模拟器
Write-Output "Stopping emulator $DEVICE_SERIAL..."
Start-Sleep -Seconds 5  # 确保所有操作完成后再终止模拟器
& adb -s $DEVICE_SERIAL emu kill
Write-Output "@@@@@@ Finish ($DEVICE_SERIAL): $PACKAGE_NAME @@@@@@@"

exit