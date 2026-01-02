# 实验数据分析工具集

本目录包含 Flink vs Storm At-Least-Once 语义对比实验的所有数据分析工具。

## 📁 文件结构

```
data/
├── README.md                           # 本文件
├── ANALYSIS_GUIDE.md                   # 详细使用指南
├── baseline_data.csv                   # 基线实验数据
├── stats_snapshots.csv                 # 完整实验快照数据
├── flink_external_fault_*.csv          # Flink外部故障数据
├── storm_external_fault_*.csv          # Storm外部故障数据
├── analyze_experiment_results.py       # 主分析脚本（基础图表）
├── advanced_analysis.py                # 高级分析脚本（统计检验）
├── run_analysis.bat                    # Windows一键运行脚本
└── figures/                            # 生成的图表输出目录
    ├── 01_baseline_latency_comparison.png
    ├── 02_baseline_throughput_comparison.png
    ├── ...
    └── experiment_summary_report.txt
```

## 🚀 快速开始

### 方法1: 一键运行（推荐）

**Windows系统:**
```bash
双击运行 run_analysis.bat
```

### 方法2: 命令行运行

**1. 安装依赖:**
```bash
pip install pandas matplotlib numpy scipy
```

**2. 运行基础分析:**
```bash
cd d:/vDesktop/DaseBigData-2025-E/data
python analyze_experiment_results.py
```

**3. 运行高级分析:**
```bash
python advanced_analysis.py
```

## 📊 生成的图表

### 基础分析脚本 (analyze_experiment_results.py)

| 图表编号 | 文件名 | 内容 | 类型 |
|---------|--------|------|------|
| 图1 | `01_baseline_latency_comparison.png` | 基线延迟对比（P50/P95/P99） | 柱状图 |
| 图2 | `02_baseline_throughput_comparison.png` | 基线吞吐量对比 | 柱状图 |
| 图3 | `03_internal_fault_duplicate_rate.png` | 内部故障重复率趋势 | 折线图 |
| 图4 | `04_external_fault_duplicate_rate.png` | 外部故障重复率对比 | 分组柱状图 |
| 图5 | `05_external_fault_latency_comparison.png` | 外部故障延迟影响 | 分组柱状图 |
| 图6 | `06_external_fault_throughput_degradation.png` | 外部故障吞吐量下降 | 分组柱状图 |
| 图7 | `07_comprehensive_comparison_radar.png` | 综合性能对比 | 雷达图 |

### 高级分析脚本 (advanced_analysis.py)

| 图表编号 | 文件名 | 内容 | 类型 |
|---------|--------|------|------|
| 图8 | `08_flink_correlation_matrix.png` | Flink指标相关性矩阵 | 热力图 |
| 图9 | `09_storm_correlation_matrix.png` | Storm指标相关性矩阵 | 热力图 |

### 生成的报告

| 报告名称 | 内容 |
|---------|------|
| `experiment_summary_report.txt` | 实验数据汇总统计 |
| `advanced_analysis_report.txt` | 深度分析报告（最优/最差场景） |
| `statistical_test_results.csv` | 统计显著性检验结果（T检验） |

## 📈 数据说明

### CSV 文件格式

所有CSV文件包含以下关键字段：

| 字段 | 说明 | 单位 |
|------|------|------|
| `job_type` | 框架类型 | flink / storm |
| `total_messages` | 处理总消息数 | 条 |
| `unique_messages` | 唯一消息数 | 条 |
| `avg_latency` | 平均延迟 | ms |
| `p50_latency` | P50延迟 | ms |
| `p95_latency` | P95延迟 | ms |
| `p99_latency` | P99延迟 | ms |
| `duplicate_messages` | 重复消息数 | 条 |
| `duplicate_rate` | 重复率 | % |
| `max_process_count` | 最大重复处理次数 | 次 |
| `throughput_per_sec` | 吞吐量 | msg/s |
| `note` | 实验备注 | - |

### 数据文件说明

1. **baseline_data.csv** - 基线实验数据
   - 包含 Flink 和 Storm 在无故障场景下的性能基准
   - 用于图1、图2、图5、图6的基准对比

2. **stats_snapshots.csv** - 完整实验快照
   - 包含所有实验的原始数据（65条记录）
   - 用于高级分析和统计检验

3. **flink_external_fault_*.csv** - Flink 外部故障数据
   - `worker` - Kill TaskManager 故障
   - `master` - Kill JobManager 故障
   - `network` - 网络隔离故障

4. **storm_external_fault_*.csv** - Storm 外部故障数据
   - `worker` - Kill Worker 故障
   - `master` - Kill Nimbus 故障
   - `network` - 网络隔离故障

## 🎨 图表定制

### 修改颜色

在脚本中修改全局变量：

```python
FLINK_COLOR = '#E74C3C'  # Flink 红色
STORM_COLOR = '#3498DB'  # Storm 蓝色
```

### 修改分辨率

修改 `savefig` 参数：

```python
plt.savefig(filename, dpi=300)  # 论文级别 300dpi
plt.savefig(filename, dpi=150)  # PPT级别 150dpi
```

### 修改图表尺寸

修改 `figsize` 参数：

```python
fig, ax = plt.subplots(figsize=(10, 6))  # (宽, 高) 英寸
```

## 📋 分析流程

```
1. 数据准备
   ↓
2. 运行 analyze_experiment_results.py
   - 生成 7 个基础图表
   - 生成汇总报告
   ↓
3. 运行 advanced_analysis.py
   - 统计显著性检验
   - 相关性分析
   - 异常值检测
   - 详细分析报告
   ↓
4. 查看结果
   - figures/ 目录下的所有图表
   - 两份文本报告
```

## 🔧 故障排查

### 问题1: 中文乱码

**Windows:**
```python
plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei']
```

**Linux:**
```bash
sudo apt-get install fonts-wqy-zenhei
```

**macOS:**
```bash
brew install font-wqy-zenhei
```

### 问题2: 缺少依赖包

```bash
pip install pandas matplotlib numpy scipy seaborn
```

### 问题3: 数据文件找不到

确保在 `data/` 目录下运行脚本：

```bash
cd d:/vDesktop/DaseBigData-2025-E/data
python analyze_experiment_results.py
```

## 📊 关键发现总结

根据已有数据分析：

### 基线实验
- ✅ Flink 和 Storm 都实现了 0 消息丢失
- ✅ 吞吐量相近 (Flink: 3040 msg/s, Storm: 3044 msg/s)
- ⚡ Flink 平均延迟更低 (512ms vs 725ms)
- ⚠️ Storm P99延迟更高 (8111ms vs 4255ms)

### 外部故障实验
- 🔄 Flink 重复率显著高于 Storm
  - Worker故障: Flink 平均约4倍于Storm
  - Network故障: Flink 平均约2倍于Storm
- ⏱️ Storm 恢复速度更快
- 📉 故障场景下 Storm 吞吐量下降更少

## 📚 扩展阅读

- 完整实验设计: `../README_NEW.md`
- 环境配置指南: `../config/环境部署.md`
- 实验设计文档: `../config/实验设计.md`
- 数据库设计: `../code/database/init.sql`

## 💡 使用建议

### 论文写作
1. 所有图表已设置为 300dpi，适合直接用于论文
2. 建议使用矢量图格式 (PDF/SVG)：
   ```python
   plt.savefig('figure.pdf')  # 矢量图
   ```

### PPT展示
1. 降低分辨率以减小文件大小：
   ```python
   plt.savefig('figure.png', dpi=150)
   ```
2. 使用 16:9 比例的图表：
   ```python
   figsize=(12, 6.75)  # 16:9 比例
   ```

### 数据更新
1. 添加新实验数据到对应的 CSV 文件
2. 重新运行分析脚本自动更新所有图表
3. 无需修改代码，脚本会自动适应新数据

## 🎓 联系与支持

如有问题或建议，请参考：
- 详细使用指南: `ANALYSIS_GUIDE.md`
- 项目主README: `../README_NEW.md`

---

**最后更新**: 2026-01-02
**版本**: v1.0
