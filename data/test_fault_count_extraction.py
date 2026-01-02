#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
测试脚本：验证故障次数提取功能

测试 note 字段的 -X-60 格式识别
"""

import re

def extract_fault_count(note):
    """
    从 note 字段中提取故障次数
    格式: ****-X-60 其中 X 是故障次数
    """
    if note is None or note == '':
        return None
    
    # 匹配格式: -数字-数字 (如 -2-60, -4-60)
    match = re.search(r'-(\d+)-(\d+)$', str(note))
    if match:
        return int(match.group(1))  # 返回第一个数字（故障次数）
    
    return None

# 测试用例
test_cases = [
    "flink-qps3000-data1800000-外部故障jm-2-60",
    "flink-qps3000-data1800000-外部故障jm-1-60",
    "flink-qps3000-data1800000-外部故障jm-3-60",
    "flink-qps3000-data1800000-外部故障jm-4-60",
    "storm-qps3000-data1800000-外部故障worker-2-60",
    "storm-qps3000-data1800000-外部故障worker-1-60",
    "storm-qps3000-data1800000-外部故障worker-4-60",
    "flink-qps3000-data1800000-外部故障network-2-60",
    "flink-qps3000-data1800000-基线",  # 没有次数
    "storm-qps3000-data1800000-基线",
    None,  # 空值
    "",  # 空字符串
]

print("=" * 80)
print("故障次数提取测试")
print("=" * 80)
print()

success_count = 0
fail_count = 0

for note in test_cases:
    result = extract_fault_count(note)
    
    # 预期结果
    if note and '-2-60' in note:
        expected = 2
    elif note and '-1-60' in note:
        expected = 1
    elif note and '-3-60' in note:
        expected = 3
    elif note and '-4-60' in note:
        expected = 4
    else:
        expected = None
    
    # 检查结果
    status = "✓" if result == expected else "✗"
    if result == expected:
        success_count += 1
    else:
        fail_count += 1
    
    print(f"{status} note: {note}")
    print(f"   提取次数: {result}, 预期: {expected}")
    print()

print("=" * 80)
print(f"测试结果: 成功 {success_count}, 失败 {fail_count}")
print("=" * 80)

if fail_count == 0:
    print("✅ 所有测试通过！")
else:
    print("❌ 存在失败的测试用例，请检查正则表达式")
