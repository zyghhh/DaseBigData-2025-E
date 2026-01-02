#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
高级数据分析脚本 - 统计检验与深度分析

功能：
1. 统计显著性检验（T检验）
2. 相关性分析
3. 异常值检测
4. 趋势预测
5. 详细的数据报表生成
"""

import pandas as pd
import numpy as np
from scipy import stats
from pathlib import Path
import re  # 添加正则表达式支持

# 设置中文字体
import matplotlib
import matplotlib.pyplot as plt
import matplotlib.font_manager

# 强制清除字体缓存
try:
    matplotlib.font_manager._rebuild()
except:
    pass

matplotlib.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'SimHei', 'Arial Unicode MS']
matplotlib.rcParams['axes.unicode_minus'] = False
matplotlib.rcParams['font.size'] = 10

FLINK_COLOR = '#E74C3C'
STORM_COLOR = '#3498DB'

class AdvancedAnalyzer:
    def __init__(self, data_dir='./'):
        self.data_dir = Path(data_dir)
        self.output_dir = self.data_dir / 'figures'
        self.output_dir.mkdir(exist_ok=True)
    
    @staticmethod
    def extract_fault_count(note):
        """
        从 note 字段中提取故障次数
        格式: ****-X-60 其中 X 是故障次数
        """
        if pd.isna(note):
            return None
        match = re.search(r'-(\d+)-(\d+)$', str(note))
        if match:
            return int(match.group(1))
        return None
        
    def load_all_data(self):
        """加载所有实验数据"""
        print("📊 加载完整数据集...")
        
        # 读取完整的 stats_snapshots.csv
        stats_file = self.data_dir / 'stats_snapshots.csv'
        if not stats_file.exists():
            print("  ❌ 未找到 stats_snapshots.csv")
            return None
        
        df = pd.read_csv(stats_file)
        print(f"  ✓ 加载 {len(df)} 条记录")
        
        return df
    
    def statistical_significance_test(self, df):
        """统计显著性检验"""
        print("\n📈 执行统计显著性检验...")
        
        # 分离 Flink 和 Storm 数据
        flink_data = df[df['job_type'].str.contains('flink', case=False, na=False)]
        storm_data = df[df['job_type'].str.contains('storm', case=False, na=False)]
        
        results = []
        
        # 延迟对比 T检验
        if len(flink_data) > 1 and len(storm_data) > 1:
            metrics = ['avg_latency', 'p50_latency', 'p95_latency', 'p99_latency', 
                      'duplicate_rate', 'throughput_per_sec']
            
            for metric in metrics:
                flink_values = flink_data[metric].dropna()
                storm_values = storm_data[metric].dropna()
                
                if len(flink_values) > 1 and len(storm_values) > 1:
                    t_stat, p_value = stats.ttest_ind(flink_values, storm_values)
                    
                    # 计算均值差异
                    flink_mean = flink_values.mean()
                    storm_mean = storm_values.mean()
                    diff_pct = ((flink_mean - storm_mean) / storm_mean * 100) if storm_mean != 0 else 0
                    
                    results.append({
                        '指标': metric,
                        'Flink均值': f'{flink_mean:.2f}',
                        'Storm均值': f'{storm_mean:.2f}',
                        '差异%': f'{diff_pct:.2f}%',
                        't统计量': f'{t_stat:.4f}',
                        'p值': f'{p_value:.6f}',
                        '显著性': '是' if p_value < 0.05 else '否'
                    })
        
        # 保存结果
        if results:
            results_df = pd.DataFrame(results)
            output_file = self.output_dir / 'statistical_test_results.csv'
            results_df.to_csv(output_file, index=False, encoding='utf-8-sig')
            print(f"  ✓ 保存统计检验结果: {output_file}")
            
            # 打印到控制台
            print("\n统计显著性检验结果:")
            print("=" * 100)
            print(results_df.to_string(index=False))
            print("=" * 100)
    
    def correlation_analysis(self, df):
        """相关性分析"""
        print("\n📊 执行相关性分析...")
        
        # 选择数值列
        numeric_cols = ['avg_latency', 'p99_latency', 'duplicate_rate', 
                       'throughput_per_sec', 'time_window_sec']
        
        flink_data = df[df['job_type'].str.contains('flink', case=False, na=False)][numeric_cols]
        storm_data = df[df['job_type'].str.contains('storm', case=False, na=False)][numeric_cols]
        
        # 计算相关系数
        if len(flink_data) > 2:
            flink_corr = flink_data.corr()
            
            # 可视化 Flink 相关矩阵
            fig, ax = plt.subplots(figsize=(10, 8))
            im = ax.imshow(flink_corr, cmap='RdBu_r', vmin=-1, vmax=1)
            
            ax.set_xticks(np.arange(len(numeric_cols)))
            ax.set_yticks(np.arange(len(numeric_cols)))
            ax.set_xticklabels(numeric_cols, rotation=45, ha='right')
            ax.set_yticklabels(numeric_cols)
            
            # 添加数值标签
            for i in range(len(numeric_cols)):
                for j in range(len(numeric_cols)):
                    text = ax.text(j, i, f'{flink_corr.iloc[i, j]:.2f}',
                                 ha="center", va="center", color="black", fontsize=10)
            
            ax.set_title('Flink 指标相关性矩阵', fontsize=14, fontweight='bold', pad=20)
            fig.colorbar(im, ax=ax)
            
            plt.tight_layout()
            plt.savefig(self.output_dir / '08_flink_correlation_matrix.png', dpi=300, bbox_inches='tight')
            print(f"  ✓ 保存 Flink 相关性矩阵")
            plt.close()
        
        if len(storm_data) > 2:
            storm_corr = storm_data.corr()
            
            # 可视化 Storm 相关矩阵
            fig, ax = plt.subplots(figsize=(10, 8))
            im = ax.imshow(storm_corr, cmap='RdBu_r', vmin=-1, vmax=1)
            
            ax.set_xticks(np.arange(len(numeric_cols)))
            ax.set_yticks(np.arange(len(numeric_cols)))
            ax.set_xticklabels(numeric_cols, rotation=45, ha='right')
            ax.set_yticklabels(numeric_cols)
            
            for i in range(len(numeric_cols)):
                for j in range(len(numeric_cols)):
                    text = ax.text(j, i, f'{storm_corr.iloc[i, j]:.2f}',
                                 ha="center", va="center", color="black", fontsize=10)
            
            ax.set_title('Storm 指标相关性矩阵', fontsize=14, fontweight='bold', pad=20)
            fig.colorbar(im, ax=ax)
            
            plt.tight_layout()
            plt.savefig(self.output_dir / '09_storm_correlation_matrix.png', dpi=300, bbox_inches='tight')
            print(f"  ✓ 保存 Storm 相关性矩阵")
            plt.close()
    
    def outlier_detection(self, df):
        """异常值检测"""
        print("\n🔍 执行异常值检测...")
        
        metrics = ['avg_latency', 'p99_latency', 'duplicate_rate', 'throughput_per_sec']
        
        for job_type in ['flink', 'storm']:
            data = df[df['job_type'].str.contains(job_type, case=False, na=False)]
            
            if len(data) < 4:
                continue
            
            outliers = []
            
            for metric in metrics:
                values = data[metric].dropna()
                if len(values) < 4:
                    continue
                
                # 使用 IQR 方法检测异常值
                Q1 = values.quantile(0.25)
                Q3 = values.quantile(0.75)
                IQR = Q3 - Q1
                lower_bound = Q1 - 1.5 * IQR
                upper_bound = Q3 + 1.5 * IQR
                
                outlier_mask = (values < lower_bound) | (values > upper_bound)
                outlier_records = data[data[metric].isin(values[outlier_mask])]
                
                if len(outlier_records) > 0:
                    for _, record in outlier_records.iterrows():
                        outliers.append({
                            '框架': job_type.upper(),
                            '指标': metric,
                            '值': f'{record[metric]:.2f}',
                            '下界': f'{lower_bound:.2f}',
                            '上界': f'{upper_bound:.2f}',
                            '实验': record.get('note', 'N/A')
                        })
            
            if outliers:
                print(f"\n  {job_type.upper()} 异常值:")
                outliers_df = pd.DataFrame(outliers)
                print(outliers_df.to_string(index=False))
    
    def generate_detailed_report(self, df):
        """生成详细分析报告"""
        print("\n📝 生成详细分析报告...")
        
        report = []
        report.append("=" * 100)
        report.append("Flink vs Storm At-Least-Once 深度分析报告")
        report.append("=" * 100)
        report.append("")
        
        # 1. 数据概览
        report.append("【1. 数据概览】")
        report.append("-" * 100)
        report.append(f"总实验次数: {len(df)}")
        report.append(f"Flink 实验: {len(df[df['job_type'].str.contains('flink', case=False, na=False)])}")
        report.append(f"Storm 实验: {len(df[df['job_type'].str.contains('storm', case=False, na=False)])}")
        report.append("")
        
        # 2. 按故障类型分组统计
        report.append("\n【2. 按故障类型分组统计】")
        report.append("-" * 100)
        
        # 提取故障次数
        df['fault_count'] = df['note'].apply(self.extract_fault_count)
        
        fault_types = {
            '基线': 'baseline|基线',
            'Worker故障': 'worker',
            'Master故障': 'master|nimbus|jm',
            '网络故障': 'network',
            '内部故障': 'fault'
        }
        
        for fault_name, pattern in fault_types.items():
            fault_data = df[df['note'].str.contains(pattern, case=False, na=False)]
            if len(fault_data) > 0:
                report.append(f"\n{fault_name}:")
                report.append(f"  实验次数: {len(fault_data)}")
                
                # 按次数统计（如果有）
                if fault_name != '基线' and fault_data['fault_count'].notna().any():
                    report.append(f"\n  按故障次数统计:")
                    for count in sorted(fault_data['fault_count'].dropna().unique()):
                        count_data = fault_data[fault_data['fault_count'] == count]
                        report.append(f"    {int(count)}次故障: {len(count_data)} 条记录")
                        
                        flink_count = count_data[count_data['job_type'].str.contains('flink', case=False, na=False)]
                        storm_count = count_data[count_data['job_type'].str.contains('storm', case=False, na=False)]
                        
                        if len(flink_count) > 0:
                            report.append(f"      Flink: 重复率={flink_count['duplicate_rate'].mean():.4f}%, P99延迟={flink_count['p99_latency'].mean():.2f}ms")
                        if len(storm_count) > 0:
                            report.append(f"      Storm: 重复率={storm_count['duplicate_rate'].mean():.4f}%, P99延迟={storm_count['p99_latency'].mean():.2f}ms")
                else:
                    # 没有次数信息，统计整体
                    flink_fault = fault_data[fault_data['job_type'].str.contains('flink', case=False, na=False)]
                    storm_fault = fault_data[fault_data['job_type'].str.contains('storm', case=False, na=False)]
                    
                    if len(flink_fault) > 0:
                        report.append(f"  Flink 平均重复率: {flink_fault['duplicate_rate'].mean():.4f}%")
                        report.append(f"  Flink 平均P99延迟: {flink_fault['p99_latency'].mean():.2f} ms")
                    
                    if len(storm_fault) > 0:
                        report.append(f"  Storm 平均重复率: {storm_fault['duplicate_rate'].mean():.4f}%")
                        report.append(f"  Storm 平均P99延迟: {storm_fault['p99_latency'].mean():.2f} ms")
        
        # 3. 最优/最差场景
        report.append("\n\n【3. 最优/最差场景分析】")
        report.append("-" * 100)
        
        for job_type in ['flink', 'storm']:
            data = df[df['job_type'].str.contains(job_type, case=False, na=False)]
            if len(data) == 0:
                continue
            
            report.append(f"\n{job_type.upper()}:")
            
            # 最低延迟
            best_latency = data.loc[data['avg_latency'].idxmin()]
            report.append(f"  最低延迟场景: {best_latency.get('note', 'N/A')} ({best_latency['avg_latency']:.2f} ms)")
            
            # 最高延迟
            worst_latency = data.loc[data['avg_latency'].idxmax()]
            report.append(f"  最高延迟场景: {worst_latency.get('note', 'N/A')} ({worst_latency['avg_latency']:.2f} ms)")
            
            # 最低重复率
            best_dup = data.loc[data['duplicate_rate'].idxmin()]
            report.append(f"  最低重复率场景: {best_dup.get('note', 'N/A')} ({best_dup['duplicate_rate']:.4f}%)")
            
            # 最高重复率
            worst_dup = data.loc[data['duplicate_rate'].idxmax()]
            report.append(f"  最高重复率场景: {worst_dup.get('note', 'N/A')} ({worst_dup['duplicate_rate']:.4f}%)")
        
        report.append("\n" + "=" * 100)
        report.append("报告生成完成")
        report.append("=" * 100)
        
        # 保存报告
        report_file = self.output_dir / 'advanced_analysis_report.txt'
        with open(report_file, 'w', encoding='utf-8') as f:
            f.write('\n'.join(report))
        
        print(f"  ✓ 保存详细报告: {report_file}")
        print('\n'.join(report))
    
    def run_advanced_analysis(self):
        """运行所有高级分析"""
        print("="*100)
        print("🚀 开始高级数据分析")
        print("="*100)
        
        df = self.load_all_data()
        if df is None:
            print("❌ 无法加载数据，退出分析")
            return
        
        # 执行各项分析
        self.statistical_significance_test(df)
        self.correlation_analysis(df)
        self.outlier_detection(df)
        self.generate_detailed_report(df)
        
        print("\n" + "="*100)
        print(f"✅ 高级分析完成！结果保存在: {self.output_dir}")
        print("="*100)

if __name__ == '__main__':
    analyzer = AdvancedAnalyzer(data_dir='./')
    analyzer.run_advanced_analysis()
