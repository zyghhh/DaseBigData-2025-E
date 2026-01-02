# 实验数据分析指南

## 📊 数据分析脚本说明

基于 `README_NEW.md` 的实验设计，本脚本自动生成以下7个关键图表：

### 图表清单

1. **基线延迟对比 (01_baseline_latency_comparison.png)**
   - 类型: 柱状图
   - 内容: Flink vs Storm 的 P50/P95/P99 延迟对比
   - 数据来源: `baseline_data.csv`

2. **基线吞吐量对比 (02_baseline_throughput_comparison.png)**
   - 类型: 柱状图
   - 内容: 无故障场景下的吞吐量对比
   - 数据来源: `baseline_data.csv`

3. **内部故障重复率 (03_internal_fault_duplicate_rate.png)**
   - 类型: 折线图
   - 内容: 重复率随故障次数变化趋势
   - 数据来源: README 中的实验数据表格（模拟数据）

4. **外部故障重复率对比 (04_external_fault_duplicate_rate.png)**
   - 类型: 分组柱状图
   - 内容: Worker/Master/Network 三种故障场景的重复率对比
   - 数据来源: `*_external_fault_*_data.csv`

5. **外部故障延迟影响 (05_external_fault_latency_comparison.png)**
   - 类型: 分组柱状图
   - 内容: 基线 vs 各故障场景的 P99 延迟对比
   - 数据来源: `baseline_data.csv` + `*_external_fault_*_data.csv`

6. **外部故障吞吐量下降 (06_external_fault_throughput_degradation.png)**
   - 类型: 分组柱状图
   - 内容: 故障场景下的吞吐量变化
   - 数据来源: `baseline_data.csv` + `*_external_fault_*_data.csv`

7. **综合性能对比雷达图 (07_comprehensive_comparison_radar.png)**
   - 类型: 雷达图
   - 内容: 低延迟、低重复率、快速恢复、高吞吐、资源效率五个维度的综合评分
   - 数据来源: 综合所有实验结果

---

## 🚀 使用方法

### 1. 安装依赖

```bash
pip install pandas matplotlib numpy
```

### 2. 运行分析脚本

```bash
cd d:/vDesktop/DaseBigData-2025-E/data
python analyze_experiment_results.py
```

### 3. 查看结果

生成的图表保存在 `data/figures/` 目录下，包括：
- 7个PNG格式的图表文件（300dpi，适合论文使用）
- 1个文本格式的汇总报告 (`experiment_summary_report.txt`)

---

## 📁 数据文件说明

### 必需文件

| 文件名 | 内容 | 记录数 |
|--------|------|--------|
| `baseline_data.csv` | 基线实验数据（Flink + Storm） | 2条 |
| `flink_external_fault_worker_data.csv` | Flink Kill Worker 故障数据 | 多条 |
| `storm_external_fault_worker_data.csv` | Storm Kill Worker 故障数据 | 多条 |
| `flink_external_fault_master_data.csv` | Flink Kill Master 故障数据 | 多条 |
| `storm_external_fault_master_data.csv` | Storm Kill Master 故障数据 | 多条 |
| `flink_external_fault_network_data.csv` | Flink 网络隔离故障数据 | 多条 |
| `storm_external_fault_network_data.csv` | Storm 网络隔离故障数据 | 多条 |

### CSV 字段说明

| 字段名 | 说明 | 单位 |
|--------|------|------|
| `job_type` | 框架类型 (flink/storm) | - |
| `total_messages` | 处理总消息数 | 条 |
| `unique_messages` | 唯一消息数 | 条 |
| `avg_latency` | 平均延迟 | ms |
| `p50_latency` | P50延迟 | ms |
| `p95_latency` | P95延迟 | ms |
| `p99_latency` | P99延迟 | ms |
| `duplicate_messages` | 重复消息数 | 条 |
| `duplicate_rate` | 重复率 | % |
| `throughput_per_sec` | 吞吐量 | msg/s |
| `note` | 实验备注 | - |

---

## 🎨 图表定制

### 修改颜色主题

在脚本中修改以下变量：

```python
FLINK_COLOR = '#E74C3C'  # Flink颜色（红色）
STORM_COLOR = '#3498DB'  # Storm颜色（蓝色）
```

### 修改图表尺寸

修改各个 `plot_*` 函数中的 `figsize` 参数：

```python
fig, ax = plt.subplots(figsize=(10, 6))  # (宽, 高) 单位: 英寸
```

### 修改输出分辨率

修改 `savefig` 调用中的 `dpi` 参数：

```python
plt.savefig(output_path, dpi=300)  # 300dpi适合论文，150dpi适合PPT
```

---

## 📈 数据完整性检查

脚本会自动检查数据文件是否存在，缺失文件会跳过相应图表生成：

```
✓ 基线数据: 2 条记录
✓ WORKER 故障数据: Flink 4 条, Storm 4 条
✓ MASTER 故障数据: Flink 3 条, Storm 3 条
✓ NETWORK 故障数据: Flink 4 条, Storm 4 条
```

如果某个文件缺失，会显示：

```
⚠️  跳过XXX图表（无数据）
```

---

## 🔧 故障排查

### 问题1: 中文显示乱码

**解决方案**：

```python
# 在脚本开头添加字体设置
plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei']
```

或安装字体：

```bash
# Ubuntu
sudo apt-get install fonts-wqy-zenhei

# macOS
brew install font-wqy-zenhei
```

### 问题2: 数据加载失败

**检查步骤**：

1. 确认CSV文件编码为UTF-8
2. 检查文件路径是否正确
3. 确认CSV第一行为列名（不要有注释行）

**修复方法**：

```python
# 跳过注释行
df = pd.read_csv('file.csv', comment='#')

# 指定编码
df = pd.read_csv('file.csv', encoding='utf-8')
```

### 问题3: 图表不显示

脚本默认保存图表到文件而不显示窗口，如需显示：

```python
# 在每个 plt.close() 前添加
plt.show()
```

---

## 📊 扩展分析建议

### 1. 添加内部故障真实数据

当有内部故障实验数据后，修改 `plot_internal_fault_duplicate_rate()` 函数：

```python
# 从CSV读取真实数据
internal_fault_df = pd.read_csv('internal_fault_data.csv')
# 按故障次数分组统计
...
```

### 2. 添加恢复时间对比图

基于故障注入脚本的日志，可以绘制恢复时间对比：

```python
def plot_recovery_time_comparison(self):
    recovery_times = {
        'Kill Worker': {'flink': [33, 70], 'storm': [10, 15]},
        'Kill Master': {'flink': [32, 38], 'storm': [27, 33]},
        'Network': {'flink': [15, 60], 'storm': [5, 5]}
    }
    # 绘制误差条形图
    ...
```

### 3. 时序分析

分析实验过程中延迟/吞吐量随时间变化：

```python
# 需要额外的时序数据（每秒采样）
time_series_df = pd.read_csv('time_series_metrics.csv')
plt.plot(time_series_df['timestamp'], time_series_df['latency'])
```

---

## 📝 论文使用建议

### 图表质量

- 已设置 DPI=300，适合论文打印
- 建议在 LaTeX 中使用 `\includegraphics[width=0.8\textwidth]{figure.png}`
- 如需矢量图，修改保存格式为 `.pdf` 或 `.svg`

### 图表引用

在论文中的典型引用方式：

```
如图1所示，Storm在基线实验中的P99延迟(8111ms)显著高于Flink(4255ms)，
但在外部故障场景下，Storm的恢复速度(15s)明显快于Flink(33-83s)。
```

### 数据表格

脚本生成的 `experiment_summary_report.txt` 可直接转换为LaTeX表格：

```latex
\begin{table}[h]
\caption{基线实验对比}
\begin{tabular}{lcc}
\hline
指标 & Flink & Storm \\
\hline
平均延迟 (ms) & 511.98 & 725.11 \\
P99延迟 (ms) & 4255 & 8111 \\
吞吐量 (msg/s) & 3040.58 & 3044.43 \\
\hline
\end{tabular}
\end{table}
```

---

## 🎓 联系方式

如有问题，请参考：
- 实验设计: `README_NEW.md`
- 环境配置: `config/环境部署.md`
- 数据库设计: `code/database/init.sql`
