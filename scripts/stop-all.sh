#!/bin/bash
# ========================================
# 停止所有实验 - 在 Node 1 执行
# ========================================

echo "=== 停止所有服务 ==="

# 1. 停止数据生成器（Node 2）
echo "[1/4] 停止数据生成器..."
ssh node2 "pkill -f data-generator.jar"
echo "✓ 数据生成器已停止"

# 2. 停止 Flink Jobs
echo "[2/4] 停止 Flink Jobs..."
cd /opt/flink
JOBS=$(./bin/flink list 2>/dev/null | grep RUNNING | awk '{print $4}')
for job_id in $JOBS; do
    ./bin/flink cancel $job_id
done
echo "✓ Flink Jobs 已停止"

# 3. 停止 Storm Topologies
echo "[3/4] 停止 Storm Topologies..."
cd /opt/storm
TOPOLOGIES=$(./bin/storm list 2>/dev/null | grep ACTIVE | awk '{print $1}')
for topo in $TOPOLOGIES; do
    ./bin/storm kill $topo -w 0
done
echo "✓ Storm Topologies 已停止"

# 4. 停止指标收集器（Node 3）
echo "[4/4] 停止指标收集器..."
ssh node3 "pkill -f metrics-collector.jar"
echo "✓ 指标收集器已停止"

echo ""
echo "=== 所有服务已停止 ==="
