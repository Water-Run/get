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
  "head -n 20 README.md",
  "tail -n 20 README.md",
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
  "fd -t f README",
  "jq -r '.name' package.json",
  "printf 'a b\\n' | awk '{print $1, $2}'",
  "printf 'a b\\n' | awk 'NR==1 {print $1}'",
  "printf 'a b\\n' | awk '{print $1; exit}'",
  "printf 'a b\\n' | awk '{print $0}'",
  "printf 'a b\\n' | awk '{print NR, NF, $NF}' -",
  "awk -F: '{print $1}' /etc/passwd",
  "awk '{print $1}' < README.md",
  "awk --field-separator=: 'NR<=2 {print $1}' /etc/passwd",
  "sed -n '1,20p' README.md",
  "sed -n '/Harness/p' README.md",
  "sed -n -e '1p' -e '$p' README.md",
  "sed -ne '1,5p' README.md",
  "sed '20q' README.md",
  "sed -n '1p' -",
  "sed -n '1,5p' < README.md",
  "sort README.md",
  "sort --stable README.md",
  "printf '%s\\n' a b | sort | uniq -c",
  "printf '%s' -value",
  "uniq -",
  "sleep 0",
  "yes x | head -n 1",
  "echo $HOME",
  "echo \"$HOME\"",
  "grep '$HOME' README.md",
  "ls -d $HOME",
  "cat ~/README.md",
  "diff -u README.md README.md",
  "tree -L 2",
  "xxd README.md",
  "xxd -",
  "stat README.md",
  "file README.md",
  "du -sh .",
  "df -h",
  "free -h",
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
  "ping -c 1 127.0.0.1",
  "hostname -I | awk '{print $1}'",
  "netstat -an",
  "lsof -p 1",
  "ps aux | head",
  "pgrep -a ssh",
  "vmstat 1 2",
  "lsblk -f",
  "lscpu",
  "sha256sum README.md",
  "base64 README.md",
  "base64 -d encoded.txt",
  "strings get-macos-arm64 | head",
  "date +%Y",
  "date -u +%FT%TZ",
  "date -d yesterday +%F",
  "hostname",
  "hostname -f",
  "dmesg --level=err",
  "ss -ltnp",
  "arp -a",
  "route print",
  "ip addr show",
  "ip -j route show",
  "ip route get 127.0.0.1",
  "ipconfig /all",
  "nmcli device status",
  "nmcli -t -f NAME connection show",
  "netsh interface ip show config",
  "systemctl status sshd",
  "systemctl list-units --type=service",
  "journalctl -n 20 --no-pager",
  "journalctl --cursor s=0123456789abcdef",
  "timedatectl status",
  "loginctl list-sessions",
  "sysctl kernel.hostname",
  "nvidia-smi",
  "nvidia-smi -L",
  "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader",
  "curl -q -fsSL https://example.com",
  "curl -q -x http://127.0.0.1:8080 -fsSL https://example.com",
  "curl -q -I https://example.com",
  "curl -q -X GET https://example.com",
  "curl -q --request=HEAD https://example.com",
  "curl -q --url=https://example.com",
  "curl -q https:example.com",
  "curl -q -o- https://example.com",
  "curl -q --max-time 2 -H 'Accept: application/json' " &
    "'https://example.com/?q=test'",
  "wget --no-config --no-hsts -qO- https://example.com",
  "wget --no-config --no-hsts -qO- " &
    "--header='Accept: application/json' https://example.com",
  "git --no-pager log -5 --oneline",
  "git --no-pager log --color=never -1",
  "git log --format '%h %s' -1",
  "git diff --cached --no-ext-diff --no-textconv --stat",
  "git diff-files --name-only --no-ext-diff --no-textconv",
  "git show --no-ext-diff --no-textconv --stat HEAD",
  "git grep 'rm -rf'",
  "git rev-parse --show-toplevel",
  "git ls-files",
  "git branch --show-current",
  "git branch --list 'release/*'",
  "git tag --list 'v*'",
  "git config --get user.name",
  "git config --list --show-origin",
  "git remote -v",
  "git worktree list",
  "git reflog show -5",
  "git submodule status",
  "docker ps",
  "docker inspect container-name",
  "docker container ls",
  "docker image history image-name",
  "docker compose ps",
  "podman images",
  "kubectl get pods -A",
  "kubectl -n default describe pod example",
  "kubectl auth can-i get pods",
  "kubectl config current-context",
  "apt list --installed",
  "apt-cache policy bash",
  "dnf info bash",
  "pacman -Q bash",
  "brew info bash",
  "winget search PowerShell",
  "pip list",
  "pip3 show requests",
  "npm view react version",
  "cargo search serde",
  "nimble list -i",
  "tar -tf archive.tar",
  "unzip -l archive.zip",
  "unzip -p archive.zip README.md",
  "zipinfo archive.zip",
  "gzip -l archive.gz",
  "gzip -dc archive.gz",
  "zcat archive.gz | head",
  "python3 --version",
  "node --version",
  "nim --version",
  "openssl version",
  "Get-Location",
  "Write-Output $HOME",
  "Get-ChildItem $HOME | Select-Object -First 1",
  "Get-ChildItem -Force | Select-Object -First 10",
  "Get-Content README.md | Select-Object -First 5",
  "Get-Process | Sort-Object CPU | Select-Object -First 5",
  "Get-Process | Where-Object Name -eq bash",
  "Get-Process | Write-Output '@items'",
  "Get-FileHash README.md",
  "Get-Help Get-Content",
  "Resolve-Path ~",
  "ConvertTo-Json 'value'",
  "reg query HKCU\\Software",
  "sc query type= service",
  "wevtutil el",
  "certutil -hashfile README.md SHA256",
  "cmdkey /list",
  "set PATH",
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
  "awk 'BEGIN { system(\"touch x\") }'",
  "awk '{ print > \"result.txt\" }'",
  "awk -f untrusted.awk",
  "awk --load=untrusted '{print $1}'",
  "awk 'NR==1 {print $1; system(\"touch x\")}'",
  "awk '{print $1 | \"touch x\"}'",
  "awk '{getline value < \"input\"; print value}'",
  "awk '{print tolower($1)}'",
  "find . -delete",
  "find . -exec rm {} +",
  "find . -fprintf result.txt '%p\\n'",
  "find ~ -type f",
  "fd -x rm {}",
  "fd -xrm {}",
  "rg --pre 'rm -rf data' pattern",
  "sort -o result.txt input.txt",
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
  "uniq input.txt output.txt",
  "uniq - output.txt",
  "xxd -r dump.txt output.bin",
  "xxd -rps dump.txt",
  "xxd input.bin output.txt",
  "xxd - output.txt",
  "xxd ~",
  "base64 -o result.txt input.bin",
  "base64 -oresult.txt input.bin",
  "yq -i '.a=1' file.yaml",
  "yq --in-pl '.a=1' file.yaml",
  "yq -iy '.a=1' file.yaml",
  "yq --split-exp='.a' file.yaml",
  "file -C -m custom.magic",
  "pgrep --signal TERM bash",
  "sar -o activity.bin 1 1",
  "ping -f 127.0.0.1",
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
  "sensors -s",
  "sensors -As",
  "sensors --set",
  "date --set='2030-01-01'",
  "date 010100002030",
  "hostname changed-host",
  "hostname -F host.txt",
  "hostname -Fhost.txt",
  "dmesg -C",
  "dmesg --read-clear",
  "dmesg -Tc",
  "ss -K dst 127.0.0.1",
  "ss -tK dst 127.0.0.1",
  "arp -d 127.0.0.1",
  "route add default gateway 127.0.0.1",
  "route ad default gateway 127.0.0.1",
  "ip link set eth0 down",
  "ip link se eth0 down",
  "ip route fl table main",
  "ip route flush table main",
  "ip -batch commands.txt",
  "ipconfig /release",
  "ipconfig /flushdns",
  "nmcli connection down id test",
  "nmcli connection modify test ipv4.method auto",
  "nmcli connection clone test cloned",
  "nmcli connection import type wireguard file test.conf",
  "nmcli device wifi hotspot",
  "nmcli general hostname changed-host",
  "netsh interface ip set address name=x static 1.2.3.4",
  "netsh interface ip set address name=x dhcp show",
  "systemctl restart sshd",
  "systemctl restart status",
  "systemctl enable sshd",
  "systemctl help sshd",
  "systemctl -H remote.example status sshd",
  "systemctl --image=untrusted.raw status",
  "journalctl --vacuum-time=1s",
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
  "nvidia-smi -pm 1",
  "nvidia-smi --power-limit=100",
  "nvidia-smi --mig-mode=1",
  "nvidia-smi --filename=result.txt",
  "nvidia-smi -qf result.txt",
  "nvidia-smi mig -cgi 1",
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
  "git config user.name attacker",
  "git config --get user.name --unset user.email",
  "git remote add origin URL",
  "git worktree add ../other",
  "git reflog expire --all",
  "git submodule foreach 'touch marker'",
  "git submodule summary",
  "docker run alpine",
  "docker exec container sh",
  "docker container rm container",
  "docker compose up",
  "docker compose config --output compose.yml",
  "podman pull image",
  "kubectl apply -f app.yaml",
  "kubectl delete pod x",
  "kubectl exec pod -- sh",
  "kubectl config set-context x",
  "kubectl --kubeconfig=evil.yaml get pods",
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
  "dnf info bash --setopt=pluginpath=.",
  "dnf info bash -cevil.conf",
  "pacman -S package",
  "brew install package",
  "winget install package",
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
  "reg add HKCU\\Software\\X /v Y /d Z",
  "sc stop service",
  "wevtutil cl System",
  "certutil -urlcache -split -f https://example.com/file out.exe",
  "cmdkey /add:server /user:u /pass:p",
  "set NAME=value",
  "sort.exe /OUTPUT result.txt input.txt",
  "Set-Content file value",
  "printf -v 'x[$(touch marker)]' %s value",
  "Remove-Item file",
  "New-Item file",
  "Invoke-Expression 'Remove-Item file'",
  "& { Remove-Item file }",
  "[IO.File]::Delete('file')",
  "Get-Content file | ForEach-Object { Remove-Item file }",
  "Get-Process | Where-Object 'Remove-Item marker'",
  "Get-Process | Where-Object -FilterSc 'Remove-Item marker'",
  "Get-Process --% -OutVariable hidden",
  "Get-Help Get-Content -Online",
  "Get-Help Get-Content -ShowWindow",
  "Get-Package",
  "Invoke-WebRequest -Method POST -Body x https://example.com",
  "Invoke-WebRequest -OutFile file https://example.com",
  "iwr -InFile file -Method Put https://example.com"
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

  test "accepts bounded macOS performance diagnostics":
    for command in [
      "top -l 1 -n 0",
      "top -l1 -n0",
      "top -l 1 -n 15 -o cpu",
      "vm_stat",
      "sysctl hw.memsize",
      "system_profiler -detailLevel mini SPHardwareDataType"
    ]:
      check checkReadOnlyCommand(command, "zsh").allowed

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
      "awk -F: 'NR<=5 {print $1, $NF}' /etc/passwd",
      "awk '{print NR, $0}' < README.md"
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
      "awk 'BEGIN {system(\"touch marker\")}'",
      "awk '{print > \"result.txt\"}'",
      "free -h && uname -a"
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

  test "uses shell-specific aliases and null devices":
    check not checkReadOnlyCommand("printf x > nul", "bash").allowed
    check checkReadOnlyCommand("printf x > /dev/null", "bash").allowed
    check not checkReadOnlyCommand("echo x > /dev/null", "cmd").allowed
    check checkReadOnlyCommand("echo x > nul", "cmd").allowed
    check not checkReadOnlyCommand("sc query spooler", "powershell").allowed
    check checkReadOnlyCommand("sc.exe query spooler", "powershell").allowed
    check not checkReadOnlyCommand("ping -t 127.0.0.1", "cmd").allowed
    check checkReadOnlyCommand("ping -t 2 127.0.0.1", "bash").allowed
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

  test "allows only controlled non-secret shell expansions":
    check checkReadOnlyCommand("echo $HOME", "bash").allowed
    check checkReadOnlyCommand("echo \"$PWD\"", "bash").allowed
    check checkReadOnlyCommand("ls -d $HOME", "bash").allowed
    check checkReadOnlyCommand("grep '$HOME' README.md", "bash").allowed
    check checkReadOnlyCommand("grep \"$HOME\" README.md", "bash").allowed
    check checkReadOnlyCommand("cat ~/README.md", "bash").allowed
    check checkReadOnlyCommand("sort '~'", "bash").allowed
    check not checkReadOnlyCommand("sort ~", "bash").allowed
    check checkReadOnlyCommand("Write-Output $HOME", "powershell").allowed
    check checkReadOnlyCommand(
      "Get-ChildItem $HOME | Select-Object -First 1", "powershell").allowed
    check not checkReadOnlyCommand("find $HOME -type f", "bash").allowed
    check not checkReadOnlyCommand("curl -q $HOME", "bash").allowed
    check not checkReadOnlyCommand("sort $HOME", "bash").allowed
    check not checkReadOnlyCommand("xxd $HOME", "bash").allowed
    check not checkReadOnlyCommand(
      "Invoke-WebRequest $HOME", "powershell").allowed
    check not checkReadOnlyCommand("echo $API_KEY", "bash").allowed
    check not checkReadOnlyCommand("echo ${HOME}", "bash").allowed

  test "reports quantitative corpus size":
    echo "policy corpus: safe=", SafeCorpus.len,
      " attack=", AttackCorpus.len,
      " total=", SafeCorpus.len + AttackCorpus.len
    check SafeCorpus.len >= 100
    check AttackCorpus.len >= 150
