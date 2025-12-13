#!/bin/bash
# ========================================
# 查看实验状态 - 在 Node 1 执行
# ========================================

echo "=== 实验状态检查 ==="
echo ""

echo "【数据生成器 - Node 2】"
ssh node2 "ps aux | grep data-generator.jar | grep -v grep || echo '未运行'"
echo ""

echo "【Flink Jobs】"
cd /opt/flink && ./bin/flink list
echo ""

echo "【Storm Topologies】"
cd /opt/storm && ./bin/storm list
echo ""

echo "【指标收集器 - Node 3】"
ssh node3 "ps aux | grep metrics-collector.jar | grep -v grep || echo '未运行'"
echo ""

echo "【数据库统计】"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_comparison;" 2>/dev/null
