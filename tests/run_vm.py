#!/usr/bin/env python3
"""One disposable 1 GiB Ubuntu VM. Python is a test dependency, not an installer dependency."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# guest 只读共享这三个明确文件，避免把仓库里的凭据或其他用户文件一起暴露。
SOURCES = ('scripts/prepare-vps.sh', 'tests/integration.sh', 'tests/https_fixture.py')


def run(args, **kwargs):
    # 只接受参数列表，不经 shell 拼接；命令非零立即使测试失败。
    return subprocess.run(args, check=True, **kwargs)


def main():
    # root 用于本地测试夹具的 9p ownership；这不是允许在真实 VPS 上执行的入口。
    assert os.geteuid() == 0, 'The disposable VM runner requires root for 9p fixture ownership.'
    lock = json.loads((ROOT / 'tests/fixtures/ubuntu-cloud-image.json').read_text())
    output = ROOT / 'artifacts/simple-vm'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='simple-vm-') as temporary:
        work = Path(temporary)
        inputs, results = work / 'input', work / 'output'
        inputs.mkdir(); results.mkdir()
        # Never share the repository/workspace: local credential helpers may exist there.
        for name in SOURCES:
            target = inputs / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        # 云镜像先按固定大小和 SHA-256 验证，再扩容 guest 虚拟磁盘到 20 GiB。
        # 所有磁盘/共享目录都位于本次临时目录，退出时丢弃。
        disk = work / 'ubuntu.qcow2'
        digest, size = hashlib.sha256(), 0
        with urllib.request.urlopen(lock['url'], timeout=60) as source, disk.open('xb') as target:
            while block := source.read(1024 * 1024):
                size += len(block)
                assert size <= lock['size_bytes'], 'Image exceeds its fixed size.'
                digest.update(block); target.write(block)
        assert size == lock['size_bytes'] and digest.hexdigest() == lock['sha256'], 'Image lock mismatch.'
        run(['qemu-img', 'resize', str(disk), '20G'])
        info = json.loads(subprocess.check_output(['qemu-img', 'info', '--output=json', str(disk)]))
        assert info['virtual-size'] == 20 * 1024**3
        # cloud-init 在 guest 内挂载输入/输出、创建误执行保护标记，记录退出码后关机。
        # 原始配置和合成密钥不复制到 host 输出目录，只保留安装日志及通过结论。
        user_data = '''#cloud-config
package_update: false
runcmd:
  - [mkdir, -p, /mnt/input, /mnt/output]
  - [mount, -t, 9p, -o, "trans=virtio,version=9p2000.L,ro", input, /mnt/input]
  - [mount, -t, 9p, -o, "trans=virtio,version=9p2000.L", output, /mnt/output]
  - [bash, -c, "echo simple-installer-fixture > /root/SIMPLE_INSTALLER_DISPOSABLE_VM; bash /mnt/input/tests/integration.sh > /mnt/output/result.log 2>&1; code=$?; echo $code > /mnt/output/exit-code; sync; poweroff"]
'''
        (work / 'user-data').write_text(user_data)
        (work / 'meta-data').write_text('instance-id: simple-installer-fixture\nlocal-hostname: simple-fixture\n')
        seed = work / 'seed.img'
        run(['cloud-localds', str(seed), str(work / 'user-data'), str(work / 'meta-data')])
        # 优先 KVM，缺失时使用 QEMU TCG；资源固定为 1 GiB RAM、2 个 vCPU。
        # user 网络只供 guest 出站；未配置真实 VPS 登录或 host 端口转发。
        acceleration = 'kvm' if Path('/dev/kvm').exists() else 'tcg'
        command = ['qemu-system-x86_64', '-machine', f'q35,accel={acceleration}', '-cpu',
            'host' if acceleration == 'kvm' else 'max', '-m', '1024', '-smp', '2',
            '-display', 'none', '-monitor', 'none', '-serial', f'file:{work / "serial.log"}', '-no-reboot',
            '-drive', f'file={disk},if=virtio,format=qcow2',
            '-drive', f'file={seed},if=virtio,format=raw,readonly=on',
            '-virtfs', f'local,path={inputs},mount_tag=input,security_model=none,readonly=on',
            '-virtfs', f'local,path={results},mount_tag=output,security_model=none',
            '-netdev', 'user,id=network', '-device', 'virtio-net-pci,netdev=network']
        # 限制整次 VM 生命周期；即使失败也尽量保存 guest 的非密钥测试日志。
        try:
            run(command, timeout=1200)
        finally:
            if (results / 'result.log').exists():
                shutil.copyfile(results / 'result.log', output / 'result.log')
                print((results / 'result.log').read_text())
        code = int((results / 'exit-code').read_text())
        # 报告绑定本次源文件摘要和资源规格，明确真实 VPS/Mac 链路仍未在此执行。
        report = dict(exit_code=code, memory_mib=1024, disk_bytes=info['virtual-size'],
            architecture='amd64', acceleration=acceleration,
            source_sha256={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES},
            real_vps='NOT RUN', mac_link='NOT RUN')
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        assert code == 0, 'The installer integration test failed.'


if __name__ == '__main__':
    main()
