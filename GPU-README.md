# EasePi-R2 GPU / Panthor 自动加载版

当前版本默认在开机时加载 RK3588 Mali-G610 的主线 panthor 驱动。

## 已确认的 DTB 修正

GPU compatible：

```dts
compatible = "rockchip,rk3588-mali", "arm,mali-valhall-csf";
```

panthor 使用的时钟名和 IRQ 名：

```dts
clock-names = "core", "coregroup", "stacks";
interrupt-names = "job", "mmu", "gpu";
```

GPU 供电：

```dts
mali-supply = <&vdd_gpu_s0>;
sram-supply = <&vdd_gpu_mem_s0>;
```

GPU power-domain：

```dts
&{/power-management@fd8d8000/power-controller/power-domain@12} {
    domain-supply = <&vdd_gpu_s0>;
};
```

## 自动加载策略

镜像会安装：

```text
/etc/modules-load.d/easepi-r2-gpu.conf
```

内容为：

```text
panthor
```

同时保留：

```text
/etc/modprobe.d/easepi-r2-gpu.conf
```

用于 blacklist `panfrost`，避免旧 Mali 驱动方向干扰。

临时调试命令 `easepi-r2-gpu-check` 已移除。后续用综合硬件测试脚本或系统命令确认 GPU 状态。

## 构建提醒

改过 DTS/DTB 后需要重新编译 BSP。脚本会记录 BSP 输入文件 hash，避免误复用旧 `output/bsp/current`。需要强制重编时执行：

```bash
FORCE_BSP_REBUILD=yes bash build-bsp-image.sh debian trixie current minimal
```

## 启动后验证

```bash
lsmod | grep panthor
ls -l /dev/dri
dmesg | grep -Ei 'panthor|mali|gpu|fb000000|renderD' | tail -n 80
```

成功状态应包含：

```text
panthor
/dev/dri/renderD128
Initialized panthor 1.5.0 for fb000000.gpu
```

用户态可继续检查：

```bash
vulkaninfo --summary
eglinfo -B 2>/dev/null || true
```
